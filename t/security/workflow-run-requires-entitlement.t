#!/usr/bin/env perl
# ABOUTME: The workflow gate requires the request's tenant to hold an in-effect run entitlement from registry
# ABOUTME: for the slug before it asks the visitor's role, on the direct route and the callcc leg, failing closed.
use 5.42.0;
use warnings;
use utf8;
use experimental qw(signatures defer);

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw(authenticate_as import_all_workflows);
use Test::Registry::SoloVersion qw(accept_solo);
use Registry::DAO::Entitlement;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Workflow;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;

import_all_workflows($dao);

# Provisioned without accepting Solo: until 01a20415-6a27 it still receives a
# copy of every platform workflow, but holds no run right to any of them.
my $bare     = Registry::DAO::Tenant->provision( $db, { name => 'Bare Studio', slug => 'bare_studio', users => [] } );
my $BARE     = { Host => 'bare_studio.localhost' };
my $bare_dao = $dao->connect_schema('bare_studio');

sub member ( $tenant, $username, $role ) {
    my $user = Registry::DAO::User->create( $db, {
        username => $username, name => "\u$username", user_type => 'staff',
        email    => "$username\@run-entitlement.test",
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

sub runs_of ( $tdao, $slug ) {
    $tdao->db->query( q{
        SELECT count(*) FROM workflow_runs r JOIN workflows w ON w.id = r.workflow_id WHERE w.slug = ?
    }, $slug )->array->[0];
}

my $bare_admin = member( $bare, 'bare_admin', 'admin' );

subtest 'a copied workflow without a run entitlement is refused to an authorised admin' => sub {
    ok $bare_dao->find( 'Registry::DAO::Workflow', { slug => 'program-creation' } ), 'the tenant holds a copy';
    my $t = app_as($bare_admin);
    $t->get_ok( '/program-creation' => $BARE )->status_is(403);
    $t->post_ok( '/program-creation' => $BARE => form => {} )->status_is(403);
    is runs_of( $bare_dao, 'program-creation' ), 0, 'no run was created';
};

subtest 'the same tenant admits its admin once it holds the run entitlement' => sub {
    my $late     = Registry::DAO::Tenant->provision( $db, { name => 'Late Studio', slug => 'late_studio', users => [] } );
    my $late_adm = member( $late, 'late_admin', 'admin' );
    my $HOST     = { Host => 'late_studio.localhost' };
    app_as($late_adm)->get_ok( '/program-creation' => $HOST )->status_is( 403, 'refused before it holds Solo' );
    accept_solo( $db, $late );
    app_as($late_adm)->get_ok( '/program-creation' => $HOST )->status_is( 200, 'admitted once it holds Solo' );
};

# A tenant holding Solo, and a workflow registry has but Solo's set does not
# list, copied into the tenant: a copy it holds no run right to.
my $solo     = Registry::DAO::Tenant->provision( $db, { name => 'Solo Studio', slug => 'solo_studio', users => [] } );
accept_solo( $db, $solo );
my $SOLO     = { Host => 'solo_studio.localhost' };
my $solo_dao = $dao->connect_schema('solo_studio');
my $UNOFFERED = "name: unoffered-flow\nslug: unoffered-flow\ndescription: fixture\nroles: [admin]\n"
  . "steps:\n  - slug: first\n    description: x\n  - slug: second\n    description: y\n";
Registry::DAO::Workflow->from_yaml( $dao,      $UNOFFERED );
Registry::DAO::Workflow->from_yaml( $solo_dao, $UNOFFERED );
my $solo_admin = member( $solo, 'solo_admin', 'admin' );

sub children_of ( $tdao, $run ) {
    $tdao->db->query( 'SELECT count(*) FROM workflow_runs WHERE continuation_id = ?', $run->id )->array->[0];
}

subtest 'the callcc leg starts a run of a workflow the tenant holds the run entitlement for' => sub {
    my $source = $solo_dao->find( 'Registry::DAO::Workflow', { slug => 'program-creation' } )
      ->new_run( $solo_dao->db );
    app_as($solo_admin)->post_ok( "/program-creation/@{[ $source->id ]}/callcc/location-creation" => $SOLO => form => {} )
      ->status_is(302)->header_like( Location => qr{^/location-creation/} );
    is children_of( $solo_dao, $source ), 1, 'one child run continues the source run';
};

subtest 'the platform tenant runs its own workflows through the same gate' => sub {
    my $registry = Registry::DAO::Tenant->find( $db, { slug => 'registry' } );
    ok Registry::DAO::Entitlement->may_run( $db, $registry->id, $_ ), "registry holds the run right to $_"
      for qw( tenant-signup registry-storefront unoffered-flow );
    my $t = app_as();
    $t->get_ok('/tenant-signup')->status_is(200);
    $t->get_ok('/')->status_is(200);
};

# ADR 004 (b): the right to create workflows covers running the ones the
# tenant wrote. A slug registry does not have is the tenant's own.
my $OWN = "name: own-flow\nslug: own-flow\ndescription: fixture\nroles: [admin]\n"
  . "steps:\n  - slug: first\n    description: x\n  - slug: second\n    description: y\n";

subtest 'tenant-authored workflow runs under the create right' => sub {
    Registry::DAO::Workflow->from_yaml( $solo_dao, $OWN );
    ok !$dao->find( 'Registry::DAO::Workflow', { slug => 'own-flow' } ), 'registry has no such workflow';
    ok Registry::DAO::Entitlement->may_run( $db, $solo->id, 'workflow-creation' ), 'the tenant may create workflows';
    # Started rather than shown: a fixture has no templates of its own.
    app_as($solo_admin)->post_ok( '/own-flow' => $SOLO => form => {} )->status_is(302);
    is runs_of( $solo_dao, 'own-flow' ), 1, 'a run was started';
};

subtest 'tenant-authored workflow refused without the create right' => sub {
    Registry::DAO::Workflow->from_yaml( $bare_dao, $OWN );
    my $t = app_as($bare_admin);
    $t->get_ok( '/own-flow' => $BARE )->status_is(403);
    $t->post_ok( '/own-flow' => $BARE => form => {} )->status_is(403);
    is runs_of( $bare_dao, 'own-flow' ), 0, 'no run was created';
};

subtest 'case variant of a platform slug is not tenant-authored' => sub {
    ( my $variant = $UNOFFERED ) =~ s/unoffered-flow/Unoffered-Flow/g;
    Registry::DAO::Workflow->from_yaml( $solo_dao, $variant );
    my $t = app_as($solo_admin);
    $t->get_ok( '/Unoffered-Flow' => $SOLO )->status_is(403);
    $t->post_ok( '/Unoffered-Flow' => $SOLO => form => {} )->status_is(403);
    is runs_of( $solo_dao, 'Unoffered-Flow' ), 0, 'no run was created';
    ok !Registry::DAO::Entitlement->tenant_may_run( $db, 'solo_studio', $_ ), "'$_' is registry's unoffered-flow"
      for 'Unoffered-Flow', ' unoffered-flow ', "UNOFFERED-FLOW\t";
};

# --- Negative scenarios ---

subtest 'public workflow refused without tenant entitlement' => sub {
    ok $bare_dao->find( 'Registry::DAO::Workflow', { slug => 'tenant-storefront' } )->public,
      "the tenant's storefront copy is public";
    my $t = app_as();
    $t->get_ok( '/tenant-storefront' => $BARE )->status_is(403);
    $t->post_ok( '/tenant-storefront' => $BARE => form => {} )->status_is(403);
    is runs_of( $bare_dao, 'tenant-storefront' ), 0, 'no run was created';
};

sub run_state ( $tdao, $id ) {
    $tdao->db->query( 'SELECT data::text, latest_step_id FROM workflow_runs WHERE id = ?', $id )->hash;
}

subtest 'parked run refused after entitlement ends' => sub {
    my $ended     = Registry::DAO::Tenant->provision( $db, { name => 'Ended Studio', slug => 'ended_studio', users => [] } );
    my $solo_held = accept_solo( $db, $ended )->{entitlement};
    my $admin     = member( $ended, 'ended_admin', 'admin' );
    my $HOST      = { Host => 'ended_studio.localhost' };
    my $tdao      = $dao->connect_schema('ended_studio');
    my $run  = $tdao->find( 'Registry::DAO::Workflow', { slug => 'program-creation' } )->new_run( $tdao->db );
    my $step = $run->next_step( $tdao->db )->slug;
    my $url  = "/program-creation/@{[ $run->id ]}/$step";
    app_as($admin)->get_ok( $url => $HOST )->status_is( 200, 'the parked run is reachable while Solo is held' );

    $solo_held->end( $db, 'refunded', 're_run_entitlement_probe' );
    ok !Registry::DAO::Entitlement->may_run( $db, $ended->id, 'program-creation' ), 'the run right has ended';
    my $before = run_state( $tdao, $run->id );
    my $t      = app_as($admin);
    $t->get_ok( $url => $HOST )->status_is(403);
    $t->post_ok( $url => $HOST => form => { name => 'Advanced anyway' } )->status_is(403);
    is_deeply run_state( $tdao, $run->id ), $before, "the run's data did not advance";
};

subtest 'forged tenant selector does not borrow entitlement' => sub {
    my $on_solo = runs_of( $solo_dao, 'program-creation' );
    my $t       = app_as($bare_admin);
    $t->get_ok( '/program-creation' => { %$BARE, 'X-As-Tenant' => 'solo_studio' } )
      ->status_is( 403, 'a tenant header naming the entitled tenant' );
    $t->get_ok( '/program-creation' => { %$BARE, Cookie => 'as-tenant=solo_studio' } )
      ->status_is( 403, 'the as-tenant cookie naming it' );
    $t->post_ok( '/program-creation' => $BARE => form => { __tenant_slug => 'solo_studio' } )
      ->status_is( 403, 'a form __tenant_slug naming it' );
    is runs_of( $bare_dao, 'program-creation' ), 0, 'no run was created on the request tenant';
    is runs_of( $solo_dao, 'program-creation' ), $on_solo, 'nor on the named tenant';
};

subtest 'callcc into unentitled workflow refused without child run' => sub {
    ok !Registry::DAO::Entitlement->may_run( $db, $solo->id, 'unoffered-flow' ), 'Solo does not grant unoffered-flow';
    ok $solo_dao->find( 'Registry::DAO::Workflow', { slug => 'unoffered-flow' } ), 'but the tenant holds a copy';
    my $source = $solo_dao->find( 'Registry::DAO::Workflow', { slug => 'program-creation' } )
      ->new_run( $solo_dao->db );
    app_as($solo_admin)->post_ok( "/program-creation/@{[ $source->id ]}/callcc/unoffered-flow" => $SOLO => form => {} )
      ->status_is(403);
    is children_of( $solo_dao, $source ), 0, 'no child run was created';
    is runs_of( $solo_dao, 'unoffered-flow' ), 0, 'no run of the unentitled workflow exists';
};

subtest 'entitlement lookup error fails closed' => sub {
    my $t = app_as($solo_admin);
    $t->get_ok( '/program-creation' => $SOLO )->status_is( 200, 'admitted while the lookup works' );
    my $before = runs_of( $solo_dao, 'program-creation' );

    my @logged;
    $t->app->log->unsubscribe('message')->level('error');
    $t->app->log->on( message => sub ( $log, $level, @lines ) { push @logged, [ $level, "@lines" ] } );
    $db->query('ALTER TABLE registry.entitlements RENAME TO entitlements_gone');
    defer { $db->query('ALTER TABLE registry.entitlements_gone RENAME TO entitlements') }
    $t->get_ok( '/program-creation' => $SOLO )->status_is(403);
    is runs_of( $solo_dao, 'program-creation' ), $before, 'no run was created';
    ok( ( grep { $_->[0] eq 'error' && $_->[1] =~ /run entitlement lookup for 'program-creation' failed/ } @logged ),
        'the failed lookup is logged as an error' );
};

done_testing;
