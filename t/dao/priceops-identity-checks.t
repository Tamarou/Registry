#!/usr/bin/env perl
# ABOUTME: Plan authorship comes from the run's tenant, looked up by slug for every
# ABOUTME: tenant including registry; a run with no real tenant is refused.

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Registry::DAO::Tenant;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::WorkflowRun;
use Registry::DAO::PricingPlan;
use Registry::DAO::WorkflowSteps::PricingPlanBasics;
use Registry::DAO::WorkflowSteps::ReviewActivatePlan;
use Test::Registry::DB;

my $tdb = Test::Registry::DB->new;
my $dao = $tdb->db;
my $db  = $dao->db;

my $workflow = Registry::DAO::Workflow->create( $db, {
    name        => 'Plan Authorship',
    slug        => 'plan-authorship',
    description => 'Attributes a pricing plan to the run tenant',
    first_step  => 'plan-basics',
} );
for my $s (
    [ 'plan-basics'     => 'Registry::DAO::WorkflowSteps::PricingPlanBasics' ],
    [ 'review-activate' => 'Registry::DAO::WorkflowSteps::ReviewActivatePlan' ],
) {
    $workflow->add_step( $db, { slug => $s->[0], class => $s->[1], description => $s->[0] } );
}
my $basics = $workflow->get_step( $db, { slug => 'plan-basics' } );
my $review = $workflow->get_step( $db, { slug => 'review-activate' } );

my $admin = $dao->create( User => {
    username => 'authorship_admin', user_type => 'admin',
    email => 'authorship@example.com', name => 'Authorship Admin',
} );
my $tenant = Registry::DAO::Tenant->provision( $db, {
    name => 'Authorship Studio', slug => 'authorship_studio', users => [$admin],
} );
my $registry_id = $db->select( 'registry.tenants', 'id', { slug => 'registry' } )->hash->{id};

my $n = 0;
sub run_for ($data) {
    my $run = $workflow->new_run($db);
    $run->update_data( $db, $data ) if %$data;
    return $run;
}
sub submit ( $run, %extra ) {
    my $result = $basics->process( $db, {
        plan_name => 'Authorship Plan ' . ++$n, plan_type => 'subscription',
        plan_scope => 'customer', %extra,
    }, $run );
    return ( $result, Registry::DAO::WorkflowRun->find( $db, { id => $run->id } )->data->{plan_basics} );
}
sub refused ( $label, $data ) {
    my ( $result, $stored ) = submit( run_for($data) );
    ok $result->{stay}, "$label: stays on the step";
    like join( ' ', @{ $result->{errors} || [] } ), qr/tenant/i, "$label: says why";
    ok !$stored, "$label: stores nothing";
}

subtest 'platform run resolves its tenant from data' => sub {
    my $run = run_for( { __tenant_slug => 'registry' } );
    my ( $result, $stored ) = submit($run);
    ok !$result->{stay}, 'advances' or diag explain $result;
    is $stored->{offering_tenant_id}, $registry_id, 'registry row id, read from registry.tenants';

    my $created = $review->create_plan( $db, $run, $run->data, { is_active => 1 } );
    my $plan = Registry::DAO::PricingPlan->find( $db, { id => $created->{plan_id} } );
    is $plan->metadata->{offering_tenant_id}, $registry_id, 'the created plan carries it';
};

subtest 'tenant run resolves its own tenant' => sub {
    my ( $result, $stored ) = submit( run_for( { __tenant_slug => 'authorship_studio' } ) );
    ok !$result->{stay}, 'advances';
    is $stored->{offering_tenant_id}, $tenant->id, "the tenant's own id";
};

subtest 'run with no tenant refused' => sub {
    refused( 'no slug', {} );
};

subtest 'unknown or empty slug refused' => sub {
    refused( 'unknown slug', { __tenant_slug => 'no_such_tenant' } );
    refused( 'empty slug',   { __tenant_slug => '' } );
};

subtest 'case variant slug refused' => sub {
    refused( 'upper-case registry', { __tenant_slug => 'Registry' } );
    refused( 'upper-case tenant',   { __tenant_slug => 'AUTHORSHIP_STUDIO' } );
};

subtest 'slug with sql metacharacters refused' => sub {
    my $before = $db->select( 'registry.tenants', 'count(*) AS n' )->hash->{n};
    refused( 'injection', { __tenant_slug => q{registry' OR '1'='1} } );
    refused( 'drop',      { __tenant_slug => q{x'; DROP TABLE registry.tenants; --} } );
    is $db->select( 'registry.tenants', 'count(*) AS n' )->hash->{n}, $before,
        'tenants untouched';
};

subtest 'submitted tenant id ignored' => sub {
    my ( $result, $stored ) = submit(
        run_for( { __tenant_slug => 'authorship_studio' } ),
        offering_tenant_id => $registry_id, __tenant_slug => 'registry',
    );
    ok !$result->{stay}, 'advances';
    is $stored->{offering_tenant_id}, $tenant->id, 'the run tenant, not the posted one';
};

done_testing();
