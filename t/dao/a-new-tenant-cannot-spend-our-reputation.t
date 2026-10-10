# ABOUTME: A tenant whose own domain is unverified has its BULK mail capped; everything else is exempt.
# ABOUTME: Over-cap mail is held and still queued, never dropped, and auth mail is never capped.
#
# #21, unit D. #438 established that signup is scriptable -- a session cookie, a
# CSRF token, a checked box and four fields -- so without a cap a minted tenant
# could spend the platform's sending reputation on day one. #438 closed with a
# per-IP PROVISIONING limit, which throttles how fast tenants are created and
# says nothing about what one sends once it exists.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';

use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO;
use Registry::DAO::User;
use Registry::DAO::Notification;
use Registry::Job::SendNotifications;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;

{
    package QuietLog;
    sub new { bless { info => [] }, shift }
    sub info { push @{ $_[0]{info} }, $_[1] }
    sub debug {} sub warn {} sub error {}
    sub infos { @{ $_[0]{info} } }
}

my $slug = 'cap_studio';
my $tenant = Test::Registry::Fixtures::create_tenant( $db, {
    name => 'Cap Studio', slug => $slug } );
my $tdb = $dao->connect_schema($slug)->db;

my $n = 0;
sub a_parent () {
    $n++;
    my $u = Registry::DAO::User->create( $db, {
        username => "cap_p_$n", name => "Cap Parent $n",
        user_type => 'parent', email => "cap_p_$n\@test.local" } );
    $db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)', $slug, $u->id );
    return $u;
}

sub queue ( $type, $count ) {
    my @ids;
    for ( 1 .. $count ) {
        my $u = a_parent();
        my $note = Registry::DAO::Notification->create( $tdb, {
            user_id => $u->id, type => $type, channel => 'email',
            subject => "s", message => "m", metadata => {} } );
        push @ids, $note->id;
    }
    return \@ids;
}

sub drain () {
    my $log = QuietLog->new;
    my $counts = Registry::Job::SendNotifications->send_for_tenant( $dao, $slug, $log );
    return ( $counts, $log );
}

sub unsent_count () {
    return $db->query(
        "SELECT count(*) AS n FROM $slug.notifications WHERE sent_at IS NULL"
    )->hash->{n};
}

subtest 'an unverified tenant has an allowance; a verified one does not' => sub {
    # The TENANT's handle: the cap counts that tenant's own sent mail, and
    # notifications live in its schema. Passing the registry handle counts
    # registry.notifications instead, which is empty -- so the first draft of
    # this subtest passed for the wrong reason.
    my $allowance = Registry::Job::SendNotifications->send_allowance( $tdb, $slug );
    ok defined $allowance, 'unverified: capped';
    cmp_ok $allowance, '>', 0, 'with room to work in';

    $db->query(
        q{INSERT INTO registry.tenant_domains (tenant_id, domain, status, render_domain_id)
          VALUES (?, ?, 'verified', 'rdm_cap')}, $tenant->id, 'cap.example.com' );

    is Registry::Job::SendNotifications->send_allowance( $tdb, $slug ), undef,
        'a tenant that has staked its own domain is not throttled on ours';

    $db->delete( 'registry.tenant_domains', { domain => 'cap.example.com' } );

    is Registry::Job::SendNotifications->send_allowance( $db, 'registry' ), undef,
        'and the platform itself is never capped';
};

subtest 'bulk mail over the cap is held, not dropped' => sub {
    # Pretend the day's allowance is already spent, by stamping sent rows.
    # A resident user first: notifications.user_id references the tenant
    # schema's own users table, and nothing has created one yet.
    my $resident = a_parent();
    my $cap = Registry::Job::SendNotifications->UNVERIFIED_DAILY_CAP;
    $db->query( <<~"SQL", $resident->id, $cap );
        INSERT INTO $slug.notifications (user_id, type, channel, subject, message, sent_at)
        SELECT \$1, 'message_announcement', 'email', 's', 'm', now()
          FROM generate_series(1, \$2)
        SQL

    is Registry::Job::SendNotifications->send_allowance( $tdb, $slug ), 0,
        'the allowance is spent';

    my $queued = queue( 'message_announcement', 3 );
    my ( $counts, $log ) = drain();

    is $counts->{sent},   0, 'nothing bulk went out';
    is $counts->{held},   3, 'and three were HELD -- a named outcome, not a shortfall';
    ok scalar( grep { /over its sending cap/ } $log->infos ),
        'and an operator is told, rather than left to infer it';

    # The point: still queued. Not deleted, not stamped failed.
    for my $id (@$queued) {
        my $row = $db->query(
            "SELECT sent_at, failed_at FROM $slug.notifications WHERE id = ?", $id )->hash;
        ok $row, 'the row still exists';
        ok !defined $row->{sent_at},   'unsent';
        ok !defined $row->{failed_at}, 'and not marked failed -- it is held, not broken';
    }
};

subtest 'auth and transactional mail is never capped' => sub {
    # The allowance is still spent from the subtest above. These must go anyway:
    # capping a magic link locks a tenant out of its own account, and a parent
    # is waiting on a confirmation.
    my $before = unsent_count();
    queue( 'magic_link_login', 1 );
    queue( 'enrollment_confirmation', 1 );
    queue( 'message_emergency', 1 );

    my ( $counts, undef ) = drain();
    is $counts->{sent}, 3,
        'a magic link, a confirmation and an emergency all went out while over cap';

    # The bulk backlog from the previous subtest is STILL held -- that is the
    # design, not a leak: held mail stays queued for a later run. So the
    # assertion is that none of these three joined it, not that nothing is held.
    is $counts->{held}, 3, 'and the earlier bulk backlog is still waiting, untouched';
};

subtest 'a verified tenant sends its bulk mail regardless' => sub {
    $db->query(
        q{INSERT INTO registry.tenant_domains (tenant_id, domain, status, render_domain_id)
          VALUES (?, ?, 'verified', 'rdm_cap2')}, $tenant->id, 'cap2.example.com' );

    queue( 'message_announcement', 2 );
    my ( $counts, undef ) = drain();
    is $counts->{held}, 0, 'nothing held once the domain is verified';
    # The two new ones AND the backlog held while unverified: verifying the
    # domain releases what was waiting, which is the behaviour a tenant would
    # expect after fixing their DNS.
    cmp_ok $counts->{sent}, '>=', 5,
        'the new bulk mail went out, and so did the released backlog';

    $db->delete( 'registry.tenant_domains', { domain => 'cap2.example.com' } );
};

done_testing;
