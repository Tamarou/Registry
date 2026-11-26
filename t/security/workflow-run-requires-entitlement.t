#!/usr/bin/env perl
# ABOUTME: The workflow gate requires the request's tenant to hold an in-effect run entitlement from registry
# ABOUTME: for the slug before it asks the visitor's role, on the direct route and the callcc leg, failing closed.
use 5.42.0;
use warnings;
use utf8;
use experimental 'signatures';

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

done_testing;
