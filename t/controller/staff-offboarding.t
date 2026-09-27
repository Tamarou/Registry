#!/usr/bin/env perl
# ABOUTME: Tests that deactivating a staff member revokes every way back in.
# ABOUTME: Three login paths and two already-issued credentials, because a guard on some is none.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw( authenticate_as );
use Registry::DAO::User;
use Registry::DAO::MagicLinkToken;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;
my $db = $dao->db;

my $t = Test::Registry::Mojo->new('Registry');

sub make_user ( $username, $type ) {
    return $dao->create( User => {
        username => $username, name => ucfirst $username,
        email => "$username\@test.local", user_type => $type, password => 'x',
    } );
}

subtest 'a deactivated account cannot request a magic link' => sub {
    my $leaver = make_user( 'leaver_request', 'staff' );

    $leaver->deactivate($db);

    my $before = $db->query(
        'SELECT COUNT(*) FROM magic_link_tokens WHERE user_id = ?', $leaver->id )->array->[0];

    # The same confirmation page renders either way: saying "that account is
    # closed" to an unauthenticated caller would enumerate addresses.
    $t->post_ok( '/auth/magic/request' => form => { email => $leaver->email } );

    my $after = $db->query(
        'SELECT COUNT(*) FROM magic_link_tokens WHERE user_id = ?', $leaver->id )->array->[0];
    is $after, $before, 'no token was minted';
};

subtest 'a link minted before the deactivation stops working' => sub {
    my $leaver = make_user( 'leaver_link', 'staff' );

    # Minted while still employed -- which is the case that matters. A guard only
    # at the request step would let this one through.
    my ( undef, $plaintext ) = Registry::DAO::MagicLinkToken->generate( $db, {
        user_id => $leaver->id, purpose => 'login', expires_in => 24,
    } );

    $leaver->deactivate($db);

    $t->get_ok("/auth/magic/$plaintext")->status_is(200)
      ->content_like( qr/no longer active/i,
          'the link says the account is closed rather than failing silently' );

    # And no session was established by the attempt.
    $t->get_ok('/teacher/')->status_isnt( 200,
        'and the protected page is still refused' );
};

subtest 'a session already in a browser dies on the next request' => sub {
    my $leaver = make_user( 'leaver_session', 'staff' );

    # Signed in for real, through a magic link. Test::Registry::Helpers'
    # authenticate_as cannot be used here: it installs a before_dispatch hook that
    # stashes current_user outright, so a test built on it is unable to observe any
    # change in authentication -- which is the whole subject of this subtest.
    my $t2 = Test::Registry::Mojo->new('Registry');
    my ( undef, $plaintext ) = Registry::DAO::MagicLinkToken->generate( $db, {
        user_id => $leaver->id, purpose => 'login', expires_in => 24,
    } );
    $t2->get_ok("/auth/magic/$plaintext")->status_is(200);
    $t2->post_ok("/auth/magic/$plaintext/complete")->status_is(302);

    $t2->get_ok('/teacher/')->status_is( 200, 'signed in and working' );

    # Deactivated mid-session, by somebody else.
    $leaver->deactivate($db);

    # The next request, not the next login. Someone walked out cannot be left
    # holding a working cookie until it expires.
    $t2->get_ok('/teacher/')->status_isnt( 200,
        'the very next request is refused' );
};

subtest 'a passkey outlives the account and must not admit it' => sub {
    # The passkey login path never touches a magic link, which is what makes it
    # the one to forget. Asserted at the guard rather than by driving WebAuthn:
    # the credential ceremony is not what is under test, the account check is.
    my $leaver = make_user( 'leaver_passkey', 'staff' );
    $leaver->deactivate($db);

    require Registry::Controller::Auth;
    my $c = Registry::Controller::Auth->new( app => $t->app );
    ok !$c->_login_allowed( $db, $leaver->id ),
        'login is refused for a deactivated account';

    my $working = make_user( 'stayer_passkey', 'staff' );
    ok $c->_login_allowed( $db, $working->id ),
        'and allowed for one that is still active';
};

subtest 'deactivation keeps the history that points at the account' => sub {
    my $leaver = make_user( 'leaver_history', 'staff' );
    my $off = $leaver->deactivate($db);

    ok !$off->is_active, 'the account is inactive';
    ok defined $off->deactivated_at, 'and records when';

    # The row survives, which is the whole reason this is deactivation and not
    # deletion: events.teacher_id and attendance_records.marked_by are NOT NULL
    # references, so the register that says who marked it holds this row in place.
    my $still = Registry::DAO::User->find( $db, { id => $leaver->id } );
    ok $still, 'the user row is still there';
    is $still->username, 'leaver_history', 'with its identity intact';
};

subtest 'deactivation is idempotent and reversible' => sub {
    my $leaver = make_user( 'leaver_twice', 'staff' );

    my $first = $leaver->deactivate($db);
    my $when  = $first->deactivated_at;

    # When they left is a fact; calling again is not new information about it.
    my $second = $first->deactivate($db);
    is $second->deactivated_at, $when, 'the original timestamp is kept';

    my $back = $second->reactivate($db);
    ok $back->is_active, 'and reactivation restores access';
};

subtest 'a tenant cannot be locked out of itself' => sub {
    my $admin = make_user( 'lockout_admin', 'admin' );

    my $self_ok = eval { $admin->deactivate( $db, $admin->id ); 1 };
    ok !$self_ok, 'you cannot deactivate your own account';
    like $@, qr/your own account/, 'and are told why';

    # The last active admin, deactivated by somebody else, is the same lockout by
    # a different route -- and equally unrecoverable without database access.
    $db->query(q{UPDATE users SET deactivated_at = now()
                  WHERE user_type = 'admin' AND id <> ?}, $admin->id);

    my $last_ok = eval { $admin->deactivate($db); 1 };
    ok !$last_ok, 'the last active administrator cannot be deactivated';
    like $@, qr/last active administrator/, 'and is told why';

    ok Registry::DAO::User->find( $db, { id => $admin->id } )->is_active,
        'and is still active afterwards';
};

# ---------------------------------------------------------------------------
# Morgan's screen. The capability is only real if she can reach it without you.
# ---------------------------------------------------------------------------

subtest 'the people screen lists staff and offers deactivation' => sub {
    my $admin  = make_user( 'people_admin', 'admin' );
    my $spare  = make_user( 'people_spare_admin', 'admin' );  # so the last-admin guard is not in play
    my $keeper = make_user( 'people_keeper', 'staff' );

    my $t3 = Test::Registry::Mojo->new('Registry');
    authenticate_as( $t3, $admin );

    $t3->get_ok('/admin/people')->status_is(200)
      ->content_like( qr/people_keeper|People Keeper/, 'the staff member is listed' )
      ->content_like( qr/Deactivate/, 'and there is a control to deactivate them' );

    # Not offered for your own account: the DAO refuses it, so the screen must not
    # present a button that cannot work.
    $t3->content_like( qr/That's you|That&#39;s you/,
        'your own row says so instead of offering the control' );
};

subtest 'pressing Deactivate revokes access and says so' => sub {
    my $admin  = make_user( 'press_admin', 'admin' );
    make_user( 'press_spare_admin', 'admin' );
    my $leaver = make_user( 'press_leaver', 'staff' );

    my $t4 = Test::Registry::Mojo->new('Registry');
    authenticate_as( $t4, $admin );

    $t4->post_ok("/admin/people/@{[ $leaver->id ]}/deactivate")->status_is(302);

    ok !Registry::DAO::User->find( $db, { id => $leaver->id } )->is_active,
        'the account is deactivated';

    $t4->get_ok('/admin/people')->status_is(200)
      ->content_like( qr/Deactivated/, 'the screen shows the new state' )
      ->content_like( qr/Reactivate/, 'and offers a way back' );
};

subtest 'the screen refuses what the DAO refuses, and explains' => sub {
    my $only_admin = make_user( 'solo_admin', 'admin' );

    my $t5 = Test::Registry::Mojo->new('Registry');
    authenticate_as( $t5, $only_admin );

    # Every other admin off, so this one is the last.
    $db->query(q{UPDATE users SET deactivated_at = now()
                  WHERE user_type = 'admin' AND id <> ?}, $only_admin->id);

    # Posting the id directly -- the screen does not offer this, but a stale page
    # or a typed URL can still reach it, and the refusal must hold there too.
    $t5->post_ok("/admin/people/@{[ $only_admin->id ]}/deactivate")->status_is(302);

    ok Registry::DAO::User->find( $db, { id => $only_admin->id } )->is_active,
        'the last active administrator is still active';

    $t5->get_ok('/admin/people')->status_is(200)
      ->content_like( qr/own account|last active administrator/i,
          'and the operator is told why, rather than the action silently doing nothing' );
};

done_testing;
