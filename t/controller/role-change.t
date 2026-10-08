# ABOUTME: A role can be changed on an existing account, under the same privilege rule as creating one.
# ABOUTME: users.user_type was settable at creation and never again -- no screen, no route, no DAO path.
#
# #424. Promoting a teacher to administrator, or de-privileging someone who has
# left without deleting the account and orphaning events.teacher_id, both
# required database access. For a solo operator -- the default customer -- "ask
# someone with psql" is not an answer.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw( authenticate_as );
use Registry::DAO::User;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;
my $db = $dao->db;

my $n = 0;
sub make_user ( $type ) {
    $n++;
    return $dao->create( User => {
        username => "rc_${type}_$n", name => "RC " . ucfirst($type) . " $n",
        email => "rc_${type}_$n\@test.local", user_type => $type, password => 'x',
    } );
}
sub type_of ($user) {
    return $db->query( 'SELECT user_type FROM users WHERE id = ?', $user->id )
        ->hash->{user_type};
}

subtest 'the DAO can promote and demote' => sub {
    my $admin   = make_user('admin');
    my $teacher = make_user('staff');

    my $promoted = $teacher->change_role( $db, 'admin', $admin );
    is $promoted->user_type, 'admin', 'the returned object carries the new role';
    is type_of($teacher), 'admin', 'and the row was written';

    my $demoted = $promoted->change_role( $db, 'staff', $admin );
    is type_of($teacher), 'staff', 'and back again';
    is $demoted->user_type, 'staff', 'the object follows';
};

subtest 'only an administrator may grant administrator' => sub {
    # The rule CreateUser already enforces, unchanged: the people screen is open
    # to admin AND staff, so without this a staff member could mint themselves
    # an administrator.
    my $staff  = make_user('staff');
    my $target = make_user('staff');

    my $err = do { local $@; eval { $target->change_role( $db, 'admin', $staff ) }; $@ };
    ok $err, 'a staff member cannot grant admin';
    like $err, qr/administrator/i, 'and is told why';
    is type_of($target), 'staff', 'the role is unchanged';
};

subtest 'a staff member may still set the non-privileged roles' => sub {
    my $staff  = make_user('staff');
    my $target = make_user('parent');

    $target->change_role( $db, 'student', $staff );
    is type_of($target), 'student', 'a non-admin role needs no admin';
};

subtest 'the last active administrator cannot be demoted' => sub {
    # Mirrors deactivate's guard. Demoting the only admin is the same lockout by
    # a different route, and is equally unrecoverable without psql.
    # A staff member doing it, which is the reachable case AND the threat: an
    # admin cannot be the actor here, because an admin existing would mean the
    # target was not the last one, and the target cannot act on themselves.
    my $only  = make_user('admin');
    my $staff = make_user('staff');
    $db->query( q{UPDATE users SET deactivated_at = now()
                   WHERE user_type = 'admin' AND id <> ?}, $only->id );

    my $err = do { local $@; eval { $only->change_role( $db, 'staff', $staff ) }; $@ };
    ok $err, 'refused';
    like $err, qr/last active administrator/i, 'and says so';
    is type_of($only), 'admin', 'still an admin';

    $db->query( q{UPDATE users SET deactivated_at = NULL WHERE user_type = 'admin'} );
};

subtest 'you cannot change your own role' => sub {
    # Same reasoning as deactivate refusing self-deactivation: demoting yourself
    # out of admin cannot be undone from inside the product.
    my $admin = make_user('admin');
    my $other = make_user('admin');

    my $err = do { local $@; eval { $admin->change_role( $db, 'staff', $admin ) }; $@ };
    ok $err, 'refused even with another admin present';
    like $err, qr/your own/i, 'and says whose role it is';
    is type_of($admin), 'admin', 'unchanged';
};

subtest 'an unknown role is refused rather than written' => sub {
    my $admin  = make_user('admin');
    my $target = make_user('staff');

    my $err = do { local $@; eval { $target->change_role( $db, 'wizard', $admin ) }; $@ };
    ok $err, 'refused before it reaches the CHECK constraint';
    is type_of($target), 'staff', 'unchanged';
};

subtest 'setting the role it already has is a no-op, not an error' => sub {
    my $admin  = make_user('admin');
    my $target = make_user('staff');

    my $same = $target->change_role( $db, 'staff', $admin );
    is $same->user_type, 'staff', 'returns the account';
    is type_of($target), 'staff', 'unchanged';
};

subtest 'the people screen offers the control and applies it' => sub {
    my $admin   = make_user('admin');
    my $teacher = make_user('staff');

    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper( dao => sub { $dao } );
    authenticate_as( $t, $admin );

    $t->get_ok('/admin/people')->status_is(200)
      ->content_like( qr/name="user_type"/,
          'the screen offers a role control, not just a list' );

    $t->post_ok( "/admin/people/@{[ $teacher->id ]}/role"
        => form => { user_type => 'admin' } )->status_is(302);
    is type_of($teacher), 'admin', 'the promotion took effect';
};

subtest 'the screen refuses a staff member granting admin' => sub {
    my $staff  = make_user('staff');
    my $target = make_user('staff');

    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper( dao => sub { $dao } );
    authenticate_as( $t, $staff );

    $t->post_ok( "/admin/people/@{[ $target->id ]}/role"
        => form => { user_type => 'admin' } )->status_is(302);
    is type_of($target), 'staff',
        'the refusal is enforced behind the screen, not only in front of it';
};

done_testing;
