
# Tests for the member self-service portal:
#   bacds::Scheduler::Model::MemberPortal
#   GET/POST /unearth/member and /unearth/member/portal

use 5.32.1;
use warnings;

use DateTime;
use HTTP::Request::Common;
use Test::More;
use Test::Warn;

use bacds::Scheduler;
use bacds::Scheduler::CiviCRM;
use bacds::Scheduler::Model::MemberPortal;
use bacds::Scheduler::Util::Db  qw/get_dbh/;
use bacds::Scheduler::Util::Test qw/setup_test_db get_tester/;

setup_test_db;

my $dbh  = get_dbh();
my $Test = get_tester();  # no auth needed - portal is public

# --- Mock CiviCRM so tests don't need real API keys or network ---
#
# $find_contacts_stub: arrayref of contact_ids to return, or undef for []
# $get_contact_stub:   hashref to return, or undef for the default fake contact
# $last_magic_link:    populated whenever send_magic_link_email is called
# $last_update:        populated whenever update_contact is called

my ($find_contacts_stub, $get_contact_stub, $last_magic_link, $last_update);

{
    no warnings 'redefine';

    *bacds::Scheduler::CiviCRM::new = sub {
        bless {}, shift;
    };

    *bacds::Scheduler::CiviCRM::find_member_contacts_by_email = sub {
        my ($self, $email) = @_;
        return $find_contacts_stub // [];
    };

    *bacds::Scheduler::CiviCRM::get_contact = sub {
        my ($self, $contact_id) = @_;
        return $get_contact_stub // _fake_contact($contact_id);
    };

    *bacds::Scheduler::CiviCRM::update_contact = sub {
        my ($self, $contact_id, $data) = @_;
        $last_update = { contact_id => $contact_id, data => $data };
    };

    *bacds::Scheduler::CiviCRM::send_magic_link_email = sub {
        my ($self, $contact_id, $email, $display_name, $url) = @_;
        $last_magic_link = { contact_id => $contact_id, url => $url };
    };
}

test_get_request_page();
test_post_request_link_bad_email();
test_post_request_link_unknown_email();
test_post_request_link_non_member_email();
test_post_request_link_known_email();
test_post_request_link_multiple_contacts();
test_portal_invalid_token();
test_portal_expired_token();
test_portal_used_token();
test_portal_valid_token();
test_portal_valid_token_no_membership();
test_portal_valid_token_expired_membership();
test_portal_save_success();
test_portal_save_consumes_token();

done_testing;

# --- test functions ---

sub test_get_request_page {
    my $res = $Test->request(GET '/unearth/member');
    ok $res->is_success, 'GET /unearth/member returns 200';
    like $res->content, qr{Email address}, 'shows email input';
    like $res->content, qr{Send me a link}, 'shows submit button';
}

sub test_post_request_link_bad_email {
    my $res;

    $res = $Test->request(POST '/unearth/member/request-link', { email => '' });
    ok $res->is_success, 'POST with empty email returns 200';
    like $res->content, qr{Please enter a valid email address},
        'shows validation error for empty email';


    $res = $Test->request(POST '/unearth/member/request-link', { email => 'notanemail' });
    ok $res->is_success, 'POST with no @ returns 200';
    like $res->content, qr{Please enter a valid email address},
        'shows validation error for no-@ email';
}

sub test_post_request_link_unknown_email {
    $find_contacts_stub = [];
    $last_magic_link    = undef;

    my $res;
    warning_like {
        $res = $Test->request(POST '/unearth/member/request-link',
            { email => 'unknown@example.com' }
        );
    } qr{^civicrm request_link: no contacts found for unknown\@example.com},
    'got expected warning no contacts found for unknown@example.com';

    ok $res->is_success, 'POST with unknown email returns 200';
    like $res->content, qr{Check Your Email}, 'shows confirmation page';
    ok !$last_magic_link, 'no email sent for unknown address (silent ignore)';
}

sub test_post_request_link_non_member_email {
    # Email is known in CiviCRM but the contact has no membership record;
    # find_member_contacts_by_email returns [] just like an unknown email.
    $find_contacts_stub = [];
    $last_magic_link    = undef;

    my $res;
    warning_like {
        $res = $Test->request(POST '/unearth/member/request-link',
            { email => 'nonmember@example.com' }
        );
    } qr{^civicrm request_link: no contacts found for nonmember\@example.com},
    'got expected warning for non-member email';

    ok $res->is_success, 'POST with non-member email returns 200';
    like $res->content, qr{Check Your Email}, 'shows same confirmation page as unknown email';
    ok !$last_magic_link, 'no email sent for non-member address';
}

sub test_post_request_link_known_email {
    $find_contacts_stub = [{ contact_id => 42, display_name => 'Alice' }];
    $last_magic_link    = undef;

    my $res = $Test->request(POST '/unearth/member/request-link',
        { email => 'member@example.com' }
    );

    ok $res->is_success, 'POST with known email returns 200';
    like $res->content, qr{Check Your Email}, 'shows confirmation page';

    ok $last_magic_link, 'email was sent';
    is $last_magic_link->{contact_id}, 42, 'email sent to correct contact';
    like $last_magic_link->{url}, qr{/unearth/member/portal\?token=[0-9a-f]{64}},
        'email URL contains valid portal link with token';

    my ($token) = $last_magic_link->{url} =~ /token=([0-9a-f]{64})/;
    my $row = $dbh->resultset('MemberToken')->find({ token => $token });
    ok $row,                              'token stored in database';
    is $row->civicrm_contact_id, 42,     'token linked to correct contact';
    ok !$row->used_ts,                    'token is not yet used';
}

sub test_post_request_link_multiple_contacts {
    # When multiple contacts share the email, the lowest contact_id is used
    $find_contacts_stub = [
        {contact_id => 7, display_name => 'Alice'},
        {contact_id => 99, display_name => 'Bob'},
        {contact_id => 150, display_name => 'Carlos'},
    ];
    $last_magic_link    = undef;

    $Test->request(POST '/unearth/member/request-link',
        { email => 'shared@example.com' });

    ok $last_magic_link, 'email sent for ambiguous address';
    is $last_magic_link->{contact_id}, 7, 'used the lowest contact_id';
}

sub test_portal_invalid_token {
    my $res;

    $res = $Test->request(GET '/unearth/member/portal');
    ok $res->is_success, 'GET portal without token returns 200';
    like $res->content, qr{Invalid link}, 'shows error for missing token';

    $res = $Test->request(GET '/unearth/member/portal?token=notahextoken');
    ok $res->is_success, 'GET portal with non-hex token returns 200';
    like $res->content, qr{Invalid link}, 'shows error for malformed token';

    my $short_token = 'a' x 32;  # right chars, wrong length
    $res = $Test->request(GET "/unearth/member/portal?token=$short_token");
    ok $res->is_success, 'GET portal with short token returns 200';
    like $res->content, qr{Invalid link}, 'shows error for short token';

    my $unknown_token = 'b' x 64;  # right format, not in DB
    $res = $Test->request(GET "/unearth/member/portal?token=$unknown_token");
    ok $res->is_success, 'GET portal with unknown token returns 200';
    like $res->content, qr{not valid}, 'shows error for unknown token';
}

sub test_portal_expired_token {
    my $token = 'c' x 64;
    $dbh->resultset('MemberToken')->create({
        token              => $token,
        civicrm_contact_id => 42,
        created_ts         => DateTime->now->subtract(hours => 2),
        expires_ts         => DateTime->now->subtract(hours => 1),
    });

    my $res = $Test->request(GET "/unearth/member/portal?token=$token");
    ok $res->is_success, 'GET portal with expired token returns 200';
    like $res->content, qr{expired}, 'shows expiry error';
}

sub test_portal_used_token {
    my $token = 'd' x 64;
    $dbh->resultset('MemberToken')->create({
        token              => $token,
        civicrm_contact_id => 42,
        created_ts         => DateTime->now,
        expires_ts         => DateTime->now->add(hours => 1),
        used_ts            => DateTime->now,
    });

    my $res = $Test->request(GET "/unearth/member/portal?token=$token");
    ok $res->is_success, 'GET portal with used token returns 200';
    like $res->content, qr{already been used}, 'shows already-used error';
}

sub test_portal_valid_token {
    my $token = _insert_valid_token(42);
    $get_contact_stub = _fake_contact(42);

    my $res = $Test->request(GET "/unearth/member/portal?token=$token");
    ok $res->is_success, 'GET portal with valid token returns 200';
    like $res->content, qr{Wanda},               'shows contact first name';
    like $res->content, qr{Tinasky},             'shows contact last name';
    like $res->content, qr{wanda\@example\.com}, 'shows contact email';
    like $res->content, qr{Regular},             'shows membership type';
    like $res->content, qr{2026-12-31},          'shows membership expiry';
    like $res->content, qr{input-group-text text-success}, 'shows green check for current membership';
    unlike $res->content, qr{already been used|expired|not valid|Invalid link},
        'no error message on valid token';
}

sub test_portal_valid_token_no_membership {
    my $token = _insert_valid_token(42);
    $get_contact_stub = {
        _fake_contact(42)->%*,
        membership_type_name => '',
        membership_end       => '',
        membership_is_active => undef,
    };

    my $res = $Test->request(GET "/unearth/member/portal?token=$token");
    ok $res->is_success, 'GET portal with no membership returns 200';
    like $res->content, qr{No membership record found},
        'shows error for contact with no membership history';
    unlike $res->content, qr{Save changes},
        'does not show the edit form for non-members';
}

sub test_portal_valid_token_expired_membership {
    my $token = _insert_valid_token(42);
    $get_contact_stub = {
        _fake_contact(42)->%*,
        membership_type_name => 'Regular',
        membership_end       => '2020-01-01',
        membership_is_active => 0,
    };

    my $res = $Test->request(GET "/unearth/member/portal?token=$token");
    ok $res->is_success, 'GET portal with expired membership returns 200';
    like $res->content, qr{input-group-text text-danger},   'shows red X for lapsed membership';
    unlike $res->content, qr{input-group-text text-success}, 'does not show green check';
}

sub test_portal_save_success {
    my $token = _insert_valid_token(42);
    $last_update = undef;

    my $res = $Test->request(POST '/unearth/member/portal', {
        token          => $token,
        first_name     => 'Wanda',
        last_name      => 'Tinasky',
        middle_name    => '',
        nick_name      => 'Wand',
        phone          => '415-555-1234',
        street_address => '1 Main St',
        city           => 'Berkeley',
        state          => 'California',
        postal_code    => '94701',
        country        => 'United States',
    });
    ok $res->is_success, 'POST portal with valid token returns 200';
    like $res->content, qr{Changes Saved}, 'shows success page';

    ok $last_update, 'update_contact was called';
    is $last_update->{contact_id}, 42, 'updated the correct contact';
    is $last_update->{data}{first_name}, 'Wanda', 'submitted first_name passed through';
    is $last_update->{data}{phone}, '415-555-1234', 'submitted phone passed through';

    my $row = $dbh->resultset('MemberToken')->find({ token => $token });
    ok $row->used_ts, 'token is marked used after save';
}

sub test_portal_save_consumes_token {
    my $token = _insert_valid_token(42);
    $get_contact_stub = _fake_contact(42);

    my $params = {
        token => $token, first_name => 'Wanda', last_name => 'Tinasky',
        middle_name => '', nick_name => '', phone => '',
        street_address => '', city => '', state => '', postal_code => '',
        country => 'United States',
    };

    my $res = $Test->request(POST '/unearth/member/portal', $params);
    ok $res->is_success, 'first POST succeeds';
    like $res->content, qr{Changes Saved}, 'first POST shows success';

    $res = $Test->request(POST '/unearth/member/portal', $params);
    ok $res->is_success, 'second POST with same token returns 200';
    like $res->content, qr{already been used},
        'second POST shows already-used error';
}

# --- helpers ---

sub _fake_contact {
    my ($id) = @_;
    return {
        contact_id           => $id,
        first_name           => 'Wanda',
        middle_name          => '',
        last_name            => 'Tinasky',
        nick_name            => '',
        email                => 'wanda@example.com',
        phone                => '',
        street_address       => '',
        city                 => '',
        state                => '',
        postal_code          => '',
        country              => 'United States',
        membership_type_name => 'Regular',
        membership_end       => '2026-12-31',
        membership_is_active => 1,
    };
}

sub _insert_valid_token {
    my ($contact_id) = @_;
    my $token = bacds::Scheduler::Model::MemberPortal::_generate_token();
    $dbh->resultset('MemberToken')->create({
        token              => $token,
        civicrm_contact_id => $contact_id,
        created_ts         => DateTime->now,
        expires_ts         => DateTime->now->add(hours => 1),
    });
    return $token;
}
