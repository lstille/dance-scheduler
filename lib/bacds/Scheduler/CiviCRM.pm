=head1 NAME

bacds::Scheduler::CiviCRM - Client for the CiviCRM REST API

=head1 SYNOPSIS

    my $civi = bacds::Scheduler::CiviCRM->new;

    my $contact = $civi->find_member_contacts_by_email('member@example.com');
    my $contact_id = $contacts->[0]{contact_id}
    my $contact    = $civi->get_contact($contact_id);
    $civi->update_contact($contact_id, \%new_data);
    $civi->send_magic_link_email($contact_id, $email, $display_name, $url);

=head1 DESCRIPTION

Wraps CiviCRM's REST API for the member self-service portal.

Data operations use APIv4 (POST /civicrm/ajax/api4/{Entity}/{Action}).

Email sending uses APIv3 MessageTemplate.send (POST /civicrm/ajax/rest),
which is not available in APIv4.

  Member browser          dance-scheduler (bacds.org)       CiviCRM (bacds.civicrm.org)
        |                          |                                  |
        |-- GET /member ---------->|                                  |
        |<- email form ------------|                                  |
        |                          |                                  |
        |-- POST /member/request ->|-- Email.get (find by email) ---->|
        |                          |<- contact_id --------------------|
        |                          | generate token, store in DB      |
        |                          |-- MessageTemplate.send --------->|
        |                          |   (contact_id, tplParams:{url})  |-- sends email -->member
        |<- "check your inbox" ----|                                  |
        |                          |                                  |
        |-- GET /member/portal --->|                                  |
        |   ?token=XXX             | validate token                   |
        |                          |-- Contact.get ------------------>|
        |                          |   Address.get, Phone.get         |
        |<- pre-filled form -------|<- contact data ------------------|
        |                          |                                  |
        |-- POST /member/portal -->| validate token                   |
        |   (updated fields)       |-- Contact.create (update) ------>|
        |                          |   Address.create, Phone.create   |
        |<- success page ----------|                                  |

=head2 Configuration

Two private files are required (following the same pattern as other secrets
in this app):

  Production: /var/www/bacds.org/dance-scheduler/private/civicrm-api-key
  Dev:        ~/.civicrm-api-key

  Production: /var/www/bacds.org/dance-scheduler/private/civicrm-magic-link-template-id
  Dev:        ~/.civicrm-magic-link-template-id

Each file contains a single value on one line. The template ID is the numeric
ID of the CiviCRM message template used to send the magic link email. The
template should include a {$selfservice_url} Smarty variable for the link.

The API key you generate and assign to a Contact record. That Contact has to
have Administrator permissions or at least enough permissions to view and edit
Contact, Email, Address and Phone records, and to call MessageTemplate.send.

If you need the site_key (I thought I might but currently don't seem to), it
shows up on the Contact's "API Key" screen.

=head2 handy links for development:

=over 4

=item api4 explorer

https://bacds.civicrm.org/civicrm/api4/rest#/explorer/

=item api4 docs

https://docs.civicrm.org/dev/en/latest/api/v4/usage/

=item api3 explorer

https://bacds.civicrm.org/civicrm/api3#explorer

=item the PHP version of what does this:

https://github.com/systopia/de.systopia.selfservice/blob/master/api/v3/Selfservice/Sendlink.php

=item permissions and access control

https://docs.civicrm.org/user/en/latest/initial-set-up/permissions-and-access-control/

=item auth

https://docs.civicrm.org/dev/en/latest/framework/authx/

=item api key

https://docs.civicrm.org/sysadmin/en/latest/setup/api-keys/

https://civicrm.org/extensions/api-key

https://civicrm.stackexchange.com/questions/9945/how-do-i-set-up-an-api-key-for-a-user

=back

=head1 METHODS

=cut

package bacds::Scheduler::CiviCRM;

use 5.32.1;
use warnings;

use Carp qw/croak/;
use Data::Dump qw/dump/;
use DateTime;
use JSON::MaybeXS qw/encode_json decode_json/;
use LWP::UserAgent;
use HTTP::Request::Common;

our $CIVICRM_BASE_URL = 'https://bacds.civicrm.org';

use constant DEBUG => 0;

our $MOCK_API_KEY;

sub new {
    my ($class) = @_;
    my $self = bless {}, $class;
    state $api_key     = $MOCK_API_KEY || _read_private_file('civicrm-api-key');
    state $template_id = _read_private_file('civicrm-magic-link-template-id');
    $self->{api_key}     = $api_key;
    $self->{template_id} = $template_id;
    $self->{from}        = 'noreply+bacds@notification.civimail.org';
    $self->{ua}          = LWP::UserAgent->new(timeout => 15);

    if ($ENV{CIVICRM_UA_DEBUG}) {
        $self->{ua}->add_handler("request_send",  sub { shift->dump; return });
        $self->{ua}->add_handler("response_done", sub { shift->dump; return });
    }
    return $self;
}

=head2 find_member_contacts_by_email($email)

Returns an arrayref of CiviCRM contact hashes:

    {
        contact_id => 1234,
        display_name => 'Alice Smith',
    }

(sorted ascending by id) for non-deleted, non-deceased contacts that have the
given email address AND have at least one membership record.

CiviCRM may also hold contacts who have never been members — e.g. people who
registered for an event or made a one-off payment. Those contacts are excluded
here because the member portal is specifically for reviewing and updating
membership information, and showing it to non-members would be confusing.

Returns an empty arrayref if none found.

=cut

sub find_member_contacts_by_email {
    my ($self, $email) = @_;

    my $result = $self->_call_v4('Email', 'get', {
        select  => ['contact_id', 'contact_id.display_name'],
        join    => [['Membership AS membership', 'INNER', ['contact_id', '=', 'membership.contact_id']]],
        where   => [
            ['email',                  '=', $email],
            ['contact_id.is_deleted',  '=', \0],
            ['contact_id.is_deceased', '=', \0],
        ],
        groupBy => ['contact_id'],
        orderBy => {'contact_id' => 'ASC'},
    });

    return [
        map {
            {
                contact_id   => $_->{contact_id},
                display_name => $_->{'contact_id.display_name'},
            }
        } @{ $result->{values} }
    ];
}

=head2 get_contact($contact_id)

Returns a hashref with the contact's name, email (read-only), primary
address, and primary phone. Missing fields default to ''.

=cut

sub get_contact {
    my ($self, $contact_id) = @_;

    my $contact_result = $self->_call_v4('Contact', 'get', {
        select => [qw(
            first_name
            middle_name
            last_name
            nick_name
            email_primary.email
        )],
        where => [['id', '=', $contact_id]],
    });

    my $contact = $contact_result->{values}[0]
        or croak "Contact $contact_id not found in CiviCRM";

    my $addr_result = $self->_call_v4('Address', 'get', {
        select => [qw(
            id
            street_address
            city
            state_province_id:label
            postal_code
            country_id:label
        )],
        where  => [
            ['contact_id', '=', $contact_id],
            ['is_primary',  '=', \1],
        ],
        limit => 1,
    });

    my $phone_result = $self->_call_v4('Phone', 'get', {
        select => [qw(id phone)],
        where  => [
            ['contact_id', '=', $contact_id],
            ['is_primary',  '=', \1],
        ],
        limit => 1,
    });

    my $membership_result = $self->_call_v4('Membership', 'get', {
        select  => [qw(
            end_date
            membership_type_id:name
        )],
        where   => [['contact_id', '=', $contact_id]],
        orderBy => {'end_date' => 'DESC'},
        limit   => 1,
    });

    my $addr       = $addr_result->{values}[0]       // {};
    my $phone      = $phone_result->{values}[0]      // {};
    my $membership = $membership_result->{values}[0] // {};

    return {
        contact_id           => $contact_id,
        first_name           => $contact->{first_name}              // '',
        middle_name          => $contact->{middle_name}             // '',
        last_name            => $contact->{last_name}               // '',
        nick_name            => $contact->{nick_name}               // '',
        email                => $contact->{'email_primary.email'}   // '',
        street_address       => $addr->{street_address}             // '',
        city                 => $addr->{city}                       // '',
        state                => $addr->{'state_province_id:label'}  // '',
        postal_code          => $addr->{postal_code}                // '',
        country              => $addr->{'country_id:label'}         // 'United States',
        phone                => $phone->{phone}                     // '',
        membership_type_name => $membership->{'membership_type_id:name'} // '',
        membership_end       => $membership->{end_date}             // '',
        membership_is_active => (
            $membership->{end_date}
                ? (DateTime->now->ymd le $membership->{end_date} ? 1 : 0)
                : undef
        ),
    };
}

=head2 update_contact($contact_id, \%data)

Updates the contact's name fields, primary address, and primary phone in
CiviCRM. Email is intentionally excluded (read-only). Each section is only
updated if its keys are present in %data.

=cut

sub update_contact {
    my ($self, $contact_id, $data) = @_;

    # Update core name fields
    my %name_fields;
    for my $field (qw(first_name middle_name last_name nick_name)) {
        $name_fields{$field} = $data->{$field} if exists $data->{$field};
    }
    if (%name_fields) {
        $self->_call_v4('Contact', 'update', {
            values => \%name_fields,
            where  => [['id', '=', $contact_id]],
        });
    }

    # Upsert primary address
    my %addr_fields;
    for my $field (qw(street_address city postal_code)) {
        $addr_fields{$field} = $data->{$field} if exists $data->{$field};
    }
    $addr_fields{'state_province_id:label'} = $data->{state}   if exists $data->{state};
    $addr_fields{'country_id:label'}         = $data->{country} if exists $data->{country};

    if (%addr_fields) {
        my $existing_addr = $self->_call_v4('Address', 'get', {
            select => ['id'],
            where  => [
                ['contact_id', '=', $contact_id],
                ['is_primary',  '=', \1],
            ],
            limit => 1,
        });

        if (my $addr = $existing_addr->{values}[0]) {
            $self->_call_v4('Address', 'update', {
                values => \%addr_fields,
                where  => [['id', '=', $addr->{id}]],
            });
        } else {
            $self->_call_v4('Address', 'create', {
                values => {
                    %addr_fields,
                    contact_id       => $contact_id,
                    is_primary       => \1,
                    location_type_id => 1,  # "Home"
                },
            });
        }
    }

    # Upsert primary phone
    if (exists $data->{phone} && $data->{phone} ne '') {
        my $existing_phone = $self->_call_v4('Phone', 'get', {
            select => ['id'],
            where  => [
                ['contact_id', '=', $contact_id],
                ['is_primary',  '=', \1],
            ],
            limit => 1,
        });

        if (my $phone = $existing_phone->{values}[0]) {
            $self->_call_v4('Phone', 'update', {
                values => { phone => $data->{phone} },
                where  => [['id', '=', $phone->{id}]],
            });
        } else {
            $self->_call_v4('Phone', 'create', {
                values => {
                    contact_id       => $contact_id,
                    phone            => $data->{phone},
                    is_primary       => \1,
                    location_type_id => 1,  # "Home"
                },
            });
        }
    }
}

=head2 send_magic_link_email($contact_id, $email, $display_name, $url)

Sends the magic link email to the contact via CiviCRM's MessageTemplate.send
(APIv3). The template (configured via civicrm-magic-link-template-id) must
contain a {$selfservice_url} Smarty variable.

The relevant code in api/v3/Selfservice/Sendlink.php from
git@github.com:systopia/de.systopia.selfservice.git is:

    $contact_id = min(array_keys($contact_ids));
    civicrm_api3('MessageTemplate', 'send', [
        'check_permissions' => 0,
        'id'                => $template_email_known,
        'to_name'           => civicrm_api3('Contact', 'getvalue', ['id' => $contact_id, 'return' => 'display_name']),
        'from'              => $config->getSetting('sender'),
        'contact_id'        => $contact_id,
        'to_email'          => trim($params['email']),
    ]);


=cut

sub send_magic_link_email {
    my ($self, $contact_id, $email, $display_name, $url) = @_;

    $self->_call_v3('MessageTemplate', 'send', {
        id         => $self->{template_id},
        contact_id => $contact_id,
        tplParams  => { selfservice_url => $url },
        to_email   => $email,
        from       => $self->{from},
        to_name    => $display_name,
        #to_name => civicrm_api3('Contact', 'getvalue', ['id' => $contact_id, 'return' => 'display_name']),
        #check_permissions => 0, ???
    });
}

# --- private helpers ---

sub _call_v4 {
    my ($self, $entity, $action, $params) = @_;

    my $url = $CIVICRM_BASE_URL . "/civicrm/ajax/api4/$entity/$action";
    my $req = POST($url,
        'X-Civi-Auth' => 'Bearer ' . $self->{api_key},
        # tried using the site_key in response to
        # HTTP 401 Login not permitted. Must satisfy guard (site_key, perm)
        # from https://bacds.civicrm.org/civicrm/contact/view?reset=1&cid=11
        #'X-Civi-Key' => $self->{site_key},
        # but it turned out to be some different issue and site_key is unnecessary.
        Content_Type => 'application/x-www-form-urlencoded',
        Content       => 'params='.encode_json($params),

        # To ensure broad compatibility, APIv4 REST clients should set this
        # HTTP header https://docs.civicrm.org/dev/en/latest/api/v4/rest/
        'X-Requested-With' => 'XMLHttpRequest',
    );

    say STDERR 'v4 about to send: ', $req->as_string
        if DEBUG;

    return $self->_dispatch($req);
}

# MessageTemplate.send is only available in APIv3.
sub _call_v3 {
    my ($self, $entity, $action, $params) = @_;

    my $url  = $CIVICRM_BASE_URL . '/civicrm/ajax/rest';
    my $body = encode_json({ %$params });
    my $req  = POST($url,
        'X-Civi-Auth' => 'Bearer ' . $self->{api_key},
        Content_Type  => 'application/x-www-form-urlencoded',
        Content       => [
            entity => $entity,
            action => $action,
            json => $body,
        ],
    );
    say STDERR 'v3 about to send: ', $req->as_string, "\n", $body
        if DEBUG;

    return $self->_dispatch($req);
}

sub _dispatch {
    my ($self, $req) = @_;

    my $response = $self->{ua}->request($req);

    croak "CiviCRM HTTP error: " . $response->status_line . ' - ' . $response->content
        unless $response->is_success;

    my $data = eval { decode_json($response->decoded_content) };
    croak "CiviCRM returned invalid JSON: $@\n".$response->decoded_content if $@;

    if ($data->{is_error}) {
        croak "CiviCRM API error: " . ($data->{error_message} // 'unknown error');
    }
    dump '_dispatch response:', $data if DEBUG;

    return $data;
}

sub _read_private_file {
    my ($filename) = @_;

    my @candidates = (
        (defined $ENV{HOME} ? "$ENV{HOME}/.$filename" : ()),
        "/var/www/bacds.org/dance-scheduler/private/$filename",
    );

    for my $path (@candidates) {
        next unless -e $path;
        open my $fh, '<', $path or croak "can't read $path: $!";
        my $value = <$fh>;
        chomp $value;
        return $value;
    }

    croak "Can't find private file '$filename'; tried: " . join(', ', @candidates);
}

1;
