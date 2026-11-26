#!/usr/bin/env perl
# ABOUTME: A workflow run answers only to whoever started it: its user once it has one, else the browser session.
# ABOUTME: Another user or session is refused and writes nothing to the run.
use 5.42.0;
use warnings;
use utf8;
use experimental 'signatures';

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::SoloVersion qw(accept_solo);
use Test::Registry::DB;
use Test::Registry::Helpers qw(authenticate_as import_all_workflows);
use Registry::DAO::Tenant;
use Registry::DAO::User;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;

import_all_workflows($dao);

accept_solo( $db, Registry::DAO::Tenant->provision( $db, {
    name => 'Run Owner Studio', slug => 'run_owner', users => [],
} ) );
my $tenant  = Registry::DAO::Tenant->find( $db, { slug => 'run_owner' } );
my $HOST    = { Host => 'run_owner.localhost' };
my $here_db = $dao->connect_schema('run_owner')->db;

sub member ( $username, $role ) {
    my $user = Registry::DAO::User->create( $db, {
        username => $username, name => "\u$username", user_type => 'staff',
        email    => "$username\@run-owner.test",
    } );
    $tenant->add_user( $db, $user, 0, $role );
    $db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $user->id );
    return $user;
}

sub app_as ($user = undef) {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->ua->max_redirects(0);
    authenticate_as( $t, $user ) if $user;
    return $t;
}

sub snapshot ($run_id) {
    $here_db->query( 'SELECT data::text AS data, latest_step_id FROM workflow_runs WHERE id = ?',
        $run_id )->hash;
}

my $alice = member( 'owner_alice', 'admin' );
my $bob   = member( 'owner_bob',   'admin' );
my $carol = member( 'owner_carol', 'admin' );

subtest 'user B, allowed on a workflow, is refused user A\'s run and A\'s run data is unchanged' => sub {
    my $ta = app_as($alice);
    $ta->post_ok( '/pricing-plan-creation' => $HOST => form => {} )->status_is(302);
    my ($run_id) = $ta->tx->res->headers->location =~ m{/pricing-plan-creation/([0-9a-f-]{36})/};
    ok $run_id, 'Alice has a run in progress';
    my $before = snapshot($run_id);
    like $before->{data}, qr/\Q${\ $alice->id }\E/, "the run records Alice as its user";

    my $tb = app_as($bob);
    $tb->get_ok( '/pricing-plan-creation' => $HOST )->status_is( 200, 'Bob may run pricing plan creation' );

    $tb->get_ok( "/pricing-plan-creation/$run_id/plan-basics" => $HOST )
      ->status_is( 404, "Bob cannot open Alice's run" );
    $tb->post_ok( "/pricing-plan-creation/$run_id/plan-basics" => $HOST => form => {
        plan_name => 'Bob Plan', plan_type => 'standard', plan_scope => 'customer',
    } )->status_is( 404, "Bob cannot post to Alice's run" );
    $tb->post_ok( "/pricing-plan-creation/$run_id/callcc/program-creation" => $HOST => form => {} )
      ->status_is( 404, "nor continue out of it" );

    is_deeply snapshot($run_id), $before, "Alice's run, its user included, is unchanged";

    $ta->get_ok( "/pricing-plan-creation/$run_id/plan-basics" => $HOST )
      ->status_is( 200, 'while Alice still reaches her own run' );
};

subtest 'a run started anonymously is refused to a different session' => sub {
    my $x = app_as();
    $x->post_ok( '/tenant-signup' => form => {} )->status_is(302);
    my ( $run_id, $step ) =
      $x->tx->res->headers->location =~ m{/tenant-signup/([0-9a-f-]{36})/([^/?]+)};
    ok $run_id, 'an anonymous visitor has a signup run';
    $x->get_ok("/tenant-signup/$run_id/$step")->status_is( 200, 'which their session reaches' );

    my $before = snapshot_registry($run_id);

    my $y = app_as();
    $y->get_ok("/tenant-signup/$run_id/$step")
      ->status_is( 404, 'another anonymous session cannot open it' );
    $y->post_ok( "/tenant-signup/$run_id/$step" => form => { name => 'Hijacked Studio' } )
      ->status_is( 404, 'nor post to it' );

    my $c = app_as($carol);
    $c->get_ok("/tenant-signup/$run_id/$step")
      ->status_is( 404, 'nor can a signed-in user from another session' );
    $c->post_ok( "/tenant-signup/$run_id/$step" => form => { name => 'Carol Studio' } )
      ->status_is(404);

    is_deeply snapshot_registry($run_id), $before, 'the anonymous run is unchanged';
    unlike $before->{data} // '', qr/\Q${\ $carol->id }\E/, 'and was never bound to Carol';
};

subtest 'server-owned run keys are written only after authorization passes' => sub {
    # Bob is refused before anything is written: Alice's run never gains Bob
    # as its user, not even transiently.
    my $ta = app_as($alice);
    $ta->post_ok( '/pricing-plan-creation' => $HOST => form => {} )->status_is(302);
    my ($run_id) = $ta->tx->res->headers->location =~ m{/pricing-plan-creation/([0-9a-f-]{36})/};

    my $tb = app_as($bob);
    $tb->post_ok( "/pricing-plan-creation/$run_id/plan-basics" => $HOST => form => {} )
      ->status_is(404);
    $tb->get_ok( "/pricing-plan-creation/$run_id/plan-basics" => $HOST )->status_is(404);

    my $data = snapshot($run_id)->{data};
    unlike $data, qr/\Q${\ $bob->id }\E/, "Bob's id is nowhere in Alice's run";
};

sub snapshot_registry ($run_id) {
    $db->query( 'SELECT data::text AS data, latest_step_id FROM workflow_runs WHERE id = ?',
        $run_id )->hash;
}

done_testing();
