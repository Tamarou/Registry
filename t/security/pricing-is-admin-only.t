#!/usr/bin/env perl
# ABOUTME: Only a tenant's admins may run pricing-plan-creation; staff, parents and strangers are
# ABOUTME: refused at every entry -- start, later step and callcc -- and no run is created for them.
use 5.42.0;
use warnings;
use utf8;
use experimental 'signatures';

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw(authenticate_as import_all_workflows);
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Mojo::JSON qw(decode_json);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;

# Workflows into registry first: provision copies them into each tenant.
import_all_workflows($dao);

for my $slug (qw( price_here price_there )) {
    Registry::DAO::Tenant->provision( $db, {
        name => "Price \u$slug", slug => $slug, users => [],
    } );
}
my $here  = Registry::DAO::Tenant->find( $db, { slug => 'price_here' } );
my $there = Registry::DAO::Tenant->find( $db, { slug => 'price_there' } );
my $HOST  = { Host => 'price_here.localhost' };
my $here_db = $dao->connect_schema('price_here')->db;

sub member ( $username, %roles ) {
    my $user = Registry::DAO::User->create( $db, {
        username => $username, name => "\u$username", user_type => 'staff',
        email    => "$username\@pricing-admin-only.test",
    } );
    for my $slug ( sort keys %roles ) {
        my $tenant = $slug eq 'here' ? $here : $there;
        $tenant->add_user( $db, $user, 0, $roles{$slug} );
        $db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $user->id );
    }
    return $user;
}

sub app_as ($user = undef) {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->ua->max_redirects(0);
    authenticate_as( $t, $user ) if $user;
    return $t;
}

sub pricing_runs () {
    $here_db->query( q{
        SELECT COUNT(*) FROM workflow_runs r
          JOIN workflows w ON w.id = r.workflow_id
         WHERE w.slug = 'pricing-plan-creation'
    } )->array->[0];
}

my $admin  = member( 'price_admin',  here => 'admin' );
my $staff  = member( 'price_staff',  here => 'staff' );
my $parent = member( 'price_parent', here => 'parent' );
my $split  = member( 'price_split',  here => 'staff', there => 'admin' );

subtest 'admin starts pricing plan creation' => sub {
    my $t = app_as($admin);
    $t->get_ok( '/pricing-plan-creation' => $HOST )->status_is(200)
      ->element_exists( 'form[action*="/plan-basics"]', 'the first step is rendered' )
      ->element_exists( 'input[name="plan_type"]',      'with its plan types' );

    $t->post_ok( '/pricing-plan-creation' => $HOST => form => {} )->status_is(302)
      ->header_like( Location => qr{/pricing-plan-creation/[0-9a-f-]{36}/plan-basics},
        'starting a run lands on its first step' );
    $t->get_ok( $t->tx->res->headers->location => $HOST )->status_is(200);
};

subtest 'staff refused pricing plan creation' => sub {
    my $before = pricing_runs();
    my $t = app_as($staff);
    is_deeply $t->app->workflow_roles('pricing-plan-creation'), ['admin'],
      'pricing-plan-creation is an admin-only workflow';

    $t->get_ok( '/pricing-plan-creation' => $HOST )->status_is(403);
    $t->post_ok( '/pricing-plan-creation' => $HOST => form => {} )->status_is(403);
    is pricing_runs(), $before, 'no pricing-plan-creation run was created';
};

subtest 'staff post to an admins run refused' => sub {
    my $t = app_as($admin);
    $t->post_ok( '/pricing-plan-creation' => $HOST => form => {} )->status_is(302);
    my ($run_id) = $t->tx->res->headers->location =~ m{/pricing-plan-creation/([0-9a-f-]{36})/};
    ok $run_id, 'the admin has a run in progress';

    my $snapshot = sub {
        $here_db->query( 'SELECT data::text AS data, latest_step_id FROM workflow_runs WHERE id = ?',
            $run_id )->hash;
    };
    my $before = $snapshot->();

    my $s = app_as($staff);
    $s->post_ok( "/pricing-plan-creation/$run_id/plan-basics" => $HOST => form => {
        name => 'Staff Plan', description => 'set by staff',
    } )->status_is(403);
    $s->post_ok( "/pricing-plan-creation/$run_id/pricing-model" => $HOST => form => {
        amount => 1,
    } )->status_is(403);

    is_deeply $snapshot->(), $before, "the admin's run is unchanged";
};

subtest 'staff hand posted pricing callcc refused' => sub {
    my $t = app_as($staff);
    $t->get_ok( '/program-setup' => $HOST )->status_is( 200, 'staff may run program setup' );
    my ($run_id) = $t->tx->res->body =~ m{/program-setup/([0-9a-f-]{36})/callcc/};
    ok $run_id, 'the overview has a live run';

    my $before = pricing_runs();
    $t->post_ok( "/program-setup/$run_id/callcc/pricing-plan-creation" => $HOST => form => {} )
      ->status_is(403);
    is pricing_runs(), $before, 'no pricing-plan-creation run was created';
};

subtest 'anonymous and parent refused pricing plan creation' => sub {
    my $before = pricing_runs();

    my $anon = app_as();
    $anon->get_ok( '/pricing-plan-creation' => $HOST )->status_is(302)
      ->header_like( Location => qr{^/auth/login} );
    $anon->post_ok( '/pricing-plan-creation' => $HOST => form => {} )->status_is(302)
      ->header_like( Location => qr{^/auth/login}, 'an anonymous start is sent to log in' );

    my $t = app_as($parent);
    $t->get_ok( '/pricing-plan-creation' => $HOST )->status_is(403);
    $t->post_ok( '/pricing-plan-creation' => $HOST => form => {} )->status_is(403);

    is pricing_runs(), $before, 'no pricing-plan-creation run was created';
};

subtest 'admin elsewhere but staff here refused' => sub {
    my $before = pricing_runs();
    my $t = app_as($split);
    $t->get_ok( '/pricing-plan-creation' => $HOST )->status_is(403);
    $t->post_ok( '/pricing-plan-creation' => $HOST => form => {} )->status_is(403);
    is pricing_runs(), $before, 'no pricing-plan-creation run was created';

    $t->get_ok( '/pricing-plan-creation' => { Host => 'price_there.localhost' } )
      ->status_is( 200, 'while the tenant they administer still serves it' );
};

done_testing();
