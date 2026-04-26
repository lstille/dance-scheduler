=head1 NAME

bacds::Scheduler::Model::MemberPortal - Self-service member portal logic

=head1 SYNOPSIS

    use bacds::Scheduler::Model::MemberPortal;

    # Phase 1: trigger a magic link email
    bacds::Scheduler::Model::MemberPortal->request_link($email, $dbh, $base_url);

    # Phase 2: validate the token and fetch contact data
    my $contact = bacds::Scheduler::Model::MemberPortal->get_contact_for_portal($token, $dbh);

    # Phase 2: save updated contact data and consume the token
    bacds::Scheduler::Model::MemberPortal->save_contact($token, \%form_data, $dbh);

=head1 DESCRIPTION

Implements the passwordless self-service flow:

  1. Member enters email address.
  2. If a matching CiviCRM contact is found, a one-time token is stored in
     the local database and a magic link email is sent via CiviCRM.
  3. Member clicks the link, which contains the token in the query string.
  4. The token is validated (exists, not expired, not used) and the
     contact's CiviCRM data is fetched and shown in a form.
  5. Member submits edits, the token is marked used, and CiviCRM is updated.

If multiple contacts share the email address, the one with the lowest
contact_id is used (same behaviour as de.systopia.selfservice). If no
contact is found, the call is silently ignored to prevent email enumeration.

Tokens expire after one hour.

=cut

package bacds::Scheduler::Model::MemberPortal;

use 5.32.1;
use warnings;

use Carp qw/croak/;
use DateTime;

use bacds::Scheduler::CiviCRM;

use constant TOKEN_TTL_SECONDS => 3600;  # 1 hour

=head2 request_link($email, $dbh, $base_url)

Looks up $email in CiviCRM. If a contact is found, generates a token,
stores it in the database, and triggers CiviCRM to send the magic link
email. If no contact is found, does nothing (silent ignore).

$base_url should be the scheme+host of dance-scheduler, e.g.
'https://bacds.org/dance-scheduler', used to build the portal link.

=cut

sub request_link {
    my ($class, $email, $dbh, $base_url) = @_;

    my $civi = bacds::Scheduler::CiviCRM->new;

    my $contacts = $civi->find_member_contacts_by_email($email);
    #return unless @$contacts;  # silent ignore for unknown emails
    if (!@$contacts) {
        warn "civicrm request_link: no contacts found for $email";
        return;
    }

    # Use the contact with the lowest id (first in the sorted list)
    my $contact = $contacts->[0];
    my ($contact_id, $display_name) = ($contact->{contact_id}, $contact->{display_name});

    my $token = _generate_token();
    my $now   = DateTime->now;

    $dbh->resultset('MemberToken')->create({
        token              => $token,
        civicrm_contact_id => $contact_id,
        created_ts         => $now,
        expires_ts         => $now->clone->add(seconds => TOKEN_TTL_SECONDS),
    });

    my $portal_url = "$base_url/unearth/member/portal?token=$token";
    $civi->send_magic_link_email($contact_id, $email, $display_name, $portal_url);
}

=head2 get_contact_for_portal($token, $dbh)

Validates the token and returns the contact's data from CiviCRM as a
hashref (see bacds::Scheduler::CiviCRM->get_contact for the fields).

Dies with a human-readable message if the token is invalid, expired, or
already used, so routes can pass the message directly to templates.

=cut

sub get_contact_for_portal {
    my ($class, $token, $dbh) = @_;

    my $token_row = _validate_token($token, $dbh);

    my $civi = bacds::Scheduler::CiviCRM->new;
    my $contact = $civi->get_contact($token_row->civicrm_contact_id);

    croak "No membership record found for this account.\n"
        unless defined $contact->{membership_is_active};

    return $contact;
}

=head2 save_contact($token, \%form_data, $dbh)

Re-validates the token, updates CiviCRM with the submitted form data, then
marks the token as used so it cannot be replayed. Dies with a
human-readable message on token or CiviCRM errors.

=cut

sub save_contact {
    my ($class, $token, $form_data, $dbh) = @_;

    my $token_row = _validate_token($token, $dbh);

    my $civi = bacds::Scheduler::CiviCRM->new;
    $civi->update_contact($token_row->civicrm_contact_id, $form_data);

    $token_row->update({ used_ts => DateTime->now });
}

# --- private helpers ---

# FIXME this token isn't checked that it belongs to the
# MemberToken.civicrm_contact_id, so could be used to update *any* contact
# record???
sub _validate_token {
    my ($token, $dbh) = @_;

    # Avoid a DB lookup for obvious junk (tokens are always 64 hex chars)
    croak "Invalid link." unless $token && $token =~ /\A[0-9a-f]{64}\z/;

    my $row = $dbh->resultset('MemberToken')->find({ token => $token })
        or croak "This link is not valid.";

    croak "This link has already been used. Please request a new one.\n"
        if $row->used_ts;

    croak "This link has expired. Please request a new one.\n"
        if DateTime->compare(DateTime->now, $row->expires_ts) > 0;

    return $row;
}

sub _generate_token {
    open my $fh, '<:raw', '/dev/urandom'
        or croak "can't open /dev/urandom: $!";
    read $fh, my $bytes, 32;
    close $fh;
    return unpack 'H*', $bytes;  # 64 hex chars
}

1;
