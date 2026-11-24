#!/usr/bin/env perl
# ABOUTME: Signup provisioning grants the new tenant, in registry, an in-effect entitlement to the platform's one published offer to tenants.
# ABOUTME: A bridge test: 01a20416-6d40 replaces the grant with the accept primitive and deletes this file.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;

use Test::Registry::DB;
use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::DAO::Tenant;
use Registry::DAO::Entitlement;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

$dao->import_workflows( ['workflows/tenant-signup.yml'] );
my ($workflow) = Registry::DAO::Workflow->find( $db, { slug => 'tenant-signup' } );
my ($review)   = $workflow->get_step( $db, { slug => 'review' } );

# The bootstrap seed's fixed id for Solo v1.
my $SOLO_V1 = '00000000-0000-0000-0003-000000000001';

# A signup run that has reached the review page, whose button provisions.
sub signup_run ($slug) {
    return Registry::DAO::WorkflowRun->create( $db, {
        workflow_id => $workflow->id,
        data        => {
            name            => "Studio $slug",
            subdomain       => $slug,
            admin_name      => 'Grant Admin',
            admin_email     => "${slug}_admin\@test.example",
            admin_username  => "${slug}_admin",
            admin_user_type => 'admin',
            profile         => { name => "Studio $slug", slug => $slug },
        },
    } );
}

sub tenant_id ($slug) {
    my $row = $db->query( 'SELECT id FROM registry.tenants WHERE slug = ?', $slug )->hash;
    return $row && $row->{id};
}

sub held ($slug) {
    my $id = tenant_id($slug) or return [];
    return [ Registry::DAO::Entitlement->find( $db, { holder_tenant_id => $id } ) ];
}

subtest 'signup grants an entitlement to the published platform offer' => sub {
    my $slug = 'granted_studio';
    signup_run($slug)->process( $db, $review, {} );

    ok tenant_id($slug), 'the tenant was provisioned';
    my $held = held($slug);
    is scalar @$held, 1, 'it holds one entitlement in registry';
    my $e = $held->[0];
    is $e->offer_version_id, $SOLO_V1, 'to Solo v1, the one offer to tenants';
    is $e->payment_plan_id, 'revenue_share', 'under its percentage-of-sales plan';
    ok $e->is_in_effect($db), 'in effect now';
};

$test_db->cleanup_test_database;
done_testing;
