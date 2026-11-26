#!/usr/bin/env perl
# ABOUTME: A tenant's root serves the storefront workflow whose run right it holds (ADR 004 ruling (c)).
# ABOUTME: The slug chooses nothing, and a tenant holding no storefront right gets a 404 and no run.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::SoloVersion qw(accept_solo);
use Test::Registry::DB;

use Registry::DAO qw(Workflow);
use Registry::DAO::Entitlement;
use Registry::DAO::Offer;
use Registry::DAO::Tenant;
use Mojo::Home;
use YAML::XS qw(Load);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

for my $file ( Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each ) {
    next if Load( $file->slurp )->{draft};
    Workflow->from_yaml( $dao, $file->slurp );
}

# No dao helper override: each request reads the schema its host names.
my $t = Test::Registry::Mojo->new('Registry');

# The runs of workflow $slug in schema $schema_dao.
sub runs_of ( $schema_dao, $slug ) {
    my $wf = $schema_dao->find( Workflow => { slug => $slug } ) or return 0;
    return scalar( my @runs = $schema_dao->find( WorkflowRun => { workflow_id => $wf->id } ) );
}

# GET / on $host starts a run of exactly $slug in $schema_dao.
sub root_serves ( $host, $schema_dao, $slug ) {
    my %before = map { $_ => runs_of( $schema_dao, $_ ) } qw( registry-storefront tenant-storefront );
    $t->get_ok( '/' => { Host => $host } )->status_is(200);
    for my $sf (qw( registry-storefront tenant-storefront )) {
        is runs_of( $schema_dao, $sf ) - $before{$sf}, $sf eq $slug ? 1 : 0,
            $sf eq $slug ? "$host starts a $sf run" : "$host starts no $sf run";
    }
}

subtest 'registry serves the storefront its data names' => sub {
    root_serves( 'localhost', $dao, 'registry-storefront' );
};

my $studio = Registry::DAO::Tenant->provision( $dao->db,
    { name => 'Data Studio', slug => 'data_studio', users => [] } );
accept_solo( $dao->db, $studio );

subtest 'tenant serves the storefront its data names' => sub {
    root_serves( 'data_studio.localhost', $dao->schema('data_studio'), 'tenant-storefront' );
};

subtest 'tenant without a storefront choice fails closed' => sub {
    my $bare = Registry::DAO::Tenant->provision( $dao->db,
        { name => 'Bare Studio', slug => 'bare_studio', users => [] } );
    ok $bare, 'a tenant that accepted no offer' or return;
    my $bare_dao = $dao->schema('bare_studio');
    my @before   = map { runs_of( $_, 'registry-storefront' ) + runs_of( $_, 'tenant-storefront' ) }
        $dao, $bare_dao;

    $t->get_ok( '/' => { Host => 'bare_studio.localhost' } )->status_is(404);
    $t->content_unlike( qr/Your art deserves a real business/, 'not the platform storefront' );
    is_deeply [ map { runs_of( $_, 'registry-storefront' ) + runs_of( $_, 'tenant-storefront' ) }
            $dao, $bare_dao ], \@before, 'no storefront run is created';
};

# Last: it ends registry's right to its own storefront.
subtest 'slug alone does not choose the storefront' => sub {
    my $registry = Registry::DAO::Tenant->find( $dao->db, { slug => 'registry' } );
    my $right    = Registry::DAO::Offer->find( $dao->db, { name => 'Platform run registry-storefront' } )
        ->current_version( $dao->db );
    my $held = Registry::DAO::Entitlement->find( $dao->db,
        { holder_tenant_id => $registry->id, offer_version_id => $right->id, state => 'active' } );
    ok $held, 'registry holds run:registry-storefront' or return;
    $held->end( $dao->db, 'expired', 'storefront-from-data test' );

    root_serves( 'localhost', $dao, 'tenant-storefront' );
};

# Only an explicit run right chooses: if registry has no registry-storefront
# row (a failed import), a tenant's right to create workflows must not stand in.
subtest 'the create right does not choose a storefront' => sub {
    ok Registry::DAO::Entitlement->may_run( $dao->db, $studio->id, 'workflow-creation' ),
        'the studio holds the create right';
    my $tx = $dao->db->begin;
    $dao->db->query(q{UPDATE registry.workflows SET slug = 'registry-storefront-gone' WHERE slug = 'registry-storefront'});
    is $t->app->storefront_workflow( $dao->db, 'data_studio' ), 'tenant-storefront',
        'the studio is still given tenant-storefront';
    undef $tx;    # rolled back
};

done_testing;
