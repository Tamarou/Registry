# ABOUTME: A parent's message names the school it is from and offers a reply address that reaches them.
# ABOUTME: Asserts the generated MIME headers, because the header is the thing a parent actually sees.
#
# #21, the email half. Every notification went out as a bare `noreply@` with no
# display name and no Reply-To, so nothing said which school a confirmation
# concerned and a reply reached nobody. Latent until #484 shipped a drainer --
# before that no notification was delivered at all, so no header reached anyone.
#
# These assertions read the headers off the delivered message rather than the
# notification row. A metadata assertion would pass against a From that is still
# bare, which is the whole defect.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';

use Test::Registry::DB;
use Registry::DAO;
use Registry::DAO::User;
use Registry::DAO::Tenant;
use Registry::DAO::Notification;
use Email::Sender::Simple;

local $ENV{NOTIFICATION_FROM_EMAIL} = 'noreply@platform.test';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

sub deliveries_reset () {
    Email::Sender::Simple->default_transport->clear_deliveries;
}
# The Test transport wraps each message in Email::Abstract, which has
# get_header rather than header. Unwrapped here so every assertion below reads
# the real headers off the real message.
sub last_email () {
    my @d = Email::Sender::Simple->default_transport->deliveries;
    return undef unless @d;
    my $email = $d[-1]{email};
    return $email->can('header') ? $email : $email->cast('Email::Simple');
}

# A tenant with a name that breaks a naive header: an accent, and an ampersand.
# Plus the contact address the signup form collects under the label
# "Contact Email" (stored in the column named billing_email).
my $slug = 'hdr_studio';
my $tenant = Registry::DAO::Tenant->create( $db, {
    name => "Müller & Sons Studio", slug => $slug } );
$db->query( 'SELECT clone_schema(?)', $slug );
$db->query(
    'INSERT INTO registry.tenant_profiles (tenant_id, billing_email) VALUES (?, ?)',
    $tenant->id, 'office@mullerstudio.test' );

my $tenant_db = $dao->connect_schema($slug)->db;

sub a_recipient ( $db_handle, $name ) {
    state $n = 0;
    $n++;
    return Registry::DAO::User->create( $db_handle, {
        username => "hdr_user_$n", name => $name,
        user_type => 'parent', email => "hdr_user_$n\@test.local" } );
}

sub send_one ( $db_handle, %opt ) {
    my $user = $opt{user} // a_recipient( $db_handle, 'Plain Parent' );
    my $note = Registry::DAO::Notification->create( $db_handle, {
        user_id => $user->id,
        type    => 'general',
        channel => 'email',
        subject => $opt{subject} // 'A plain subject',
        message => 'body',
        metadata => {},
    } );
    deliveries_reset();
    $note->send_email($db_handle);
    return last_email();
}

subtest 'a tenant message names the school in the From display name' => sub {
    my $email = send_one($tenant_db);
    ok $email, 'a message was delivered';

    my $from = $email->header('From');
    like $from, qr/noreply\@platform\.test/,
        'the address stays on the platform domain -- moving it needs DKIM (#21)';

    # The name is non-ASCII, so it must arrive RFC 2047 encoded rather than as
    # raw 8-bit bytes in a header.
    like $from, qr/=\?UTF-8\?B\?/, 'the display name is encoded, not raw 8-bit';
    my ($b64) = $from =~ /=\?UTF-8\?B\?([^?]+)\?=/;
    require MIME::Base64; require Encode;
    is Encode::decode( 'UTF-8', MIME::Base64::decode_base64($b64) ),
        "Müller & Sons Studio",
        'and decodes to the school name, ampersand and umlaut intact';
};

subtest 'a reply reaches the school' => sub {
    my $email = send_one($tenant_db);
    is $email->header('Reply-To'), 'office@mullerstudio.test',
        'Reply-To is the address the tenant gave as its contact';
};

subtest 'a non-ASCII subject is encoded too' => sub {
    # My own #484 subjects interpolate a session name -- "You are on the
    # waitlist: Café Kids" -- so this is reachable, not hypothetical.
    my $email = send_one( $tenant_db, subject => 'You are on the waitlist: Café Kids' );
    my $subject = $email->header('Subject');
    like $subject, qr/=\?UTF-8\?B\?/, 'encoded';
    my ($b64) = $subject =~ /=\?UTF-8\?B\?([^?]+)\?=/;
    require MIME::Base64; require Encode;
    is Encode::decode( 'UTF-8', MIME::Base64::decode_base64($b64) ),
        'You are on the waitlist: Café Kids', 'and round-trips';
};

subtest 'a recipient name with a comma is quoted, not read as two addresses' => sub {
    my $user = a_recipient( $tenant_db, 'Smith, Jones and Co' );
    my $email = send_one( $tenant_db, user => $user );
    my $to = $email->header('To');
    like $to, qr/^"Smith, Jones and Co" </,
        'the phrase is quoted, so the comma cannot split the address list';
};

subtest 'an ASCII name with no specials is left alone' => sub {
    my $user = a_recipient( $tenant_db, 'Plain Parent' );
    my $email = send_one( $tenant_db, user => $user );
    like $email->header('To'), qr/^Plain Parent </,
        'no quoting and no encoding where none is needed';
};

subtest 'platform mail keeps the platform identity' => sub {
    # The registry schema carries Registry's own messages -- magic links,
    # verification -- and must not claim to be from a tenant.
    my $email = send_one($db);
    my $from = $email->header('From');
    like $from, qr/noreply\@platform\.test/, 'from the platform address';
    unlike $from, qr/Müller|=\?UTF-8/, 'with no TENANT name attached';
    # The registry schema has a tenants row of its own, so platform mail is
    # named for the platform rather than being left bare. That is the right
    # outcome and worth pinning.
    like $from, qr/^\S/, 'and does carry a display name of its own';
    is $email->header('Reply-To'), undef,
        'and no Reply-To, rather than an empty one';
};

done_testing;
