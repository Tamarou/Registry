#!/usr/bin/env perl
# ABOUTME: Tests that an admin can reach user creation from the dashboard nav.
# ABOUTME: Walks the user-creation workflow over HTTP and checks the new account's user_type.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use lib          qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw(done_testing is ok subtest)];
defer { done_testing };

use Registry::DAO qw(User);
use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::Helpers qw(authenticate_as import_all_workflows);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

import_all_workflows($dao);

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $dao } );

my $admin = $dao->create(
    User => {
        username  => 'morgan_admin',
        user_type => 'admin',
        name      => 'Morgan Admin',
        email     => 'morgan@test.com',
    }
);
authenticate_as( $t, $admin );

# Walk the workflow the way the browser does: start it, fill the info step,
# confirm on the last step. Returns nothing; the caller reads the account back
# out of the database.
my sub create_user_through_workflow ( $form, $t = $t, $final_status = 201 ) {
    my $url =
      $t->get_ok('/user-creation')->status_is(200)->tx->res->dom->at('form[action]')
      ->{action};

    $url = $t->post_ok( $url => form => {} )->status_is(302)->tx->res->headers->location;

    $url = $t->get_ok($url)->status_is(200)->tx->res->dom->at('form[action]')->{action};

    $url =
      $t->post_ok( $url => form => $form )->status_is(302)->tx->res->headers->location;

    $url = $t->get_ok($url)->status_is(200)->tx->res->dom->at('form[action]')->{action};

    $t->post_ok( $url => form => {} )->status_is($final_status);
}

subtest 'admin navigation links to user creation' => sub {
    $t->get_ok('/admin/dashboard')->status_is(200)
      ->element_exists( 'nav.dashboard-nav a[href="/user-creation"]',
        'nav offers the user-creation workflow' );
};

# The plumbing behind a control nobody can reach is not a feature. This asserts
# the form actually offers the choice, because the step accepted user_type for a
# while before any screen could send it.
subtest 'the form offers the account type' => sub {
    $t->get_ok('/user-creation')->status_is(200);
    my $url = $t->tx->res->dom->at('form[action]')->{action};
    $url = $t->post_ok( $url => form => {} )->status_is(302)->tx->res->headers->location;
    $t->get_ok($url)->status_is(200)
      ->element_exists( 'select[name="user_type"]', 'the info step has an account-type control' )
      ->element_exists( 'select[name="user_type"] option[value="staff"]', 'staff can be chosen' )
      ->element_exists( 'select[name="user_type"] option[value="admin"]',
        'and an admin may grant admin' );
};

subtest 'the chosen user_type reaches the account' => sub {
    create_user_through_workflow(
        {
            username  => 'jamie.instructor',
            password  => 'correct-horse-battery',
            user_type => 'staff',
        }
    );

    my ($user) = $dao->find( User => { username => 'jamie.instructor' } );
    ok $user, 'account created';
    is $user && $user->user_type, 'staff', 'account is staff, as chosen on the form';
};

subtest 'a user_type the database forbids falls back to parent' => sub {
    create_user_through_workflow(
        {
            username  => 'mallory.wizard',
            password  => 'correct-horse-battery',
            user_type => 'wizard',
        }
    );

    my ($user) = $dao->find( User => { username => 'mallory.wizard' } );
    ok $user, 'account created';
    is $user && $user->user_type, 'parent', 'unknown type ignored rather than sent to the database';
};

# user-creation is reachable by staff as well as admins, so copying a requested
# user_type through unchecked would let a staff member mint an administrator --
# inert while nothing copied the field, an escalation the moment something did.
subtest 'a staff member cannot create an administrator' => sub {
    my $staffer = $dao->create(
        User => {
            username  => 'sam_staff',
            user_type => 'staff',
            name      => 'Sam Staff',
            email     => 'sam@test.com',
        }
    );

    my $st = Test::Registry::Mojo->new('Registry');
    $st->app->helper( dao => sub { $dao } );
    authenticate_as( $st, $staffer );

    # The option is not even offered to them.
    $st->get_ok('/user-creation')->status_is(200);
    my $url = $st->tx->res->dom->at('form[action]')->{action};
    $url = $st->post_ok( $url => form => {} )->status_is(302)->tx->res->headers->location;
    $st->get_ok($url)->status_is(200)
      ->element_exists( 'select[name="user_type"]', 'staff get the control' )
      ->element_exists_not( 'select[name="user_type"] option[value="admin"]',
        'but administrator is not on offer to them' );

    # And submitting it anyway is refused, because a missing option stops an
    # honest browser and nothing else. This has to walk the workflow to the
    # END: CreateUser runs on the final confirm, so a test that stops after
    # the info step creates no account at all and "no admin was minted" is
    # true for the wrong reason -- which is exactly what the first draft of
    # this subtest did, and it passed with the gate removed.
    create_user_through_workflow(
        {
            username  => 'mallory.escalated',
            password  => 'correct-horse-battery',
            user_type => 'admin',
        },
        $st,
        302,    # refused, so the run redirects back instead of creating
    );

    my ($user) = $dao->find( User => { username => 'mallory.escalated' } );
    ok !( $user && $user->user_type eq 'admin' ),
        'a staff member posting user_type=admin did not mint an administrator';
};

# The gate above trusts $run->data->{user}. This proves a client cannot supply
# it: posting a caller identity that claims admin does not get you an admin.
#
# What protects it is that _apply_server_owned_data OVERWRITES user and user_id
# from the session on every request (and deletes them when nobody is signed
# in), so a posted value is discarded whether or not the strip catches it.
# I first wrote this comment claiming it pinned the strip regex as well; it
# does not -- narrowing the strip to drop "user" leaves this subtest green,
# which I checked. The strip's coverage of "user" is currently ungraded:
# t/security/workflow-run-data-server-owned-keys.t pins __tenant_slug and
# user_id only.
subtest 'a forged caller identity does not satisfy the gate' => sub {
    my $staffer = $dao->create(
        User => {
            username  => 'sneaky_staff',
            user_type => 'staff',
            name      => 'Sneaky Staff',
            email     => 'sneaky@test.com',
        }
    );

    my $st = Test::Registry::Mojo->new('Registry');
    $st->app->helper( dao => sub { $dao } );
    authenticate_as( $st, $staffer );

    # Claim to be an admin in the same POST that asks for an admin account.
    create_user_through_workflow(
        {
            username          => 'mallory.forged',
            password          => 'correct-horse-battery',
            user_type         => 'admin',
            'user[user_type]' => 'admin',
            'user[role]'      => 'admin',
            user_id           => $staffer->id,
        },
        $st,
        302,
    );

    my ($user) = $dao->find( User => { username => 'mallory.forged' } );
    ok !( $user && $user->user_type eq 'admin' ),
        'claiming to be an admin in the form did not mint an administrator';
};
