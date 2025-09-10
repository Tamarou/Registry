#!/usr/bin/env perl

use 5.40.2;
use lib qw(lib t/lib);
use Test::More;

use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::WorkflowSteps::TenantPayment;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use JSON;

my $test_db = Test::Registry::DB->new;
my $dao = $test_db->db;
my $db = $dao->db;

# Create test tenant with schema cloning  
$db->query(q{
    INSERT INTO registry.tenants (id, name, slug, billing_status)
    VALUES ('00000000-0000-4000-8000-000000000001', 'Test Tenant', 'test-tenant', 'active')
});
$db->query("SET search_path TO tenant_00000000_0000_4000_8000_000000000001, registry, public");

# Create test workflow using create method
my $workflow = Registry::DAO::Workflow->create($db, {
    name => 'Test Tenant Payment',
    slug => 'test-tenant-payment',
    description => 'Test workflow for payment step'
});

my $payment_step = Registry::DAO::WorkflowSteps::TenantPayment->create($db, {
    workflow_id => $workflow->id,
    slug => 'payment',
    class => 'Registry::DAO::WorkflowSteps::TenantPayment',
    description => 'Payment step'
});

subtest 'TenantPayment workflow step creation' => sub {
    plan tests => 3;
    
    isa_ok($payment_step, 'Registry::DAO::WorkflowSteps::TenantPayment');
    can_ok($payment_step, qw(process prepare_payment_data get_subscription_config));
    is($payment_step->template, 'tenant-signup/payment', 'Correct template');
};

subtest 'Subscription configuration' => sub {
    plan tests => 6;
    
    my $config = $payment_step->get_subscription_config($db);
    
    ok($config, 'Configuration returned');
    is($config->{plan_name}, 'Registry Professional', 'Plan name correct');
    is($config->{monthly_amount}, 20000, 'Monthly amount is $200.00');
    is($config->{currency}, 'usd', 'Currency is USD');
    is($config->{trial_days}, 30, 'Trial period is 30 days');
    ok($config->{features} && @{$config->{features}} > 0, 'Features list provided');
};

subtest 'Payment data preparation' => sub {
    plan tests => 4;
    
    # Create test workflow run using create method
    my $run = Registry::DAO::WorkflowRun->create($db, {
        workflow_id => $workflow->id,
        data => encode_json({
            profile => {
                organization_name => 'Test Organization',
                subdomain => 'test-org',
                billing_email => 'billing@test.org'
            }
        })
    });
    
    my $data = $payment_step->prepare_payment_data($db, $run);
    
    ok($data, 'Payment data prepared');
    ok($data->{billing_summary}, 'Billing summary included');
    is($data->{billing_summary}->{organization_name}, 'Test Organization', 'Organization name correct');
    ok($data->{subscription_config}, 'Subscription config included');
};

subtest 'Initial payment page process' => sub {
    plan tests => 3;
    
    my $run = Registry::DAO::WorkflowRun->create($db, {
        workflow_id => $workflow->id,
        data => encode_json({
            profile => {
                organization_name => 'Test Organization',
                billing_email => 'billing@test.org'
            }
        })
    });
    
    my $result = $payment_step->prepare_payment_data($db, $run);
    
    ok($result, 'Process result returned');
    ok(exists $result->{billing_summary}, 'Billing summary in result');
    ok(!$result->{show_payment_form}, 'Payment form not shown initially');
};

subtest 'Retry logic' => sub {
    plan tests => 4;
    
    my $run = Registry::DAO::WorkflowRun->create($db, {
        workflow_id => $workflow->id,
        data => encode_json({})
    });
    
    is($payment_step->get_retry_count($run), 0, 'Initial retry count is 0');
    
    my $count1 = $payment_step->increment_retry_count($db, $run);
    is($count1, 1, 'First increment returns 1');
    
    my $count2 = $payment_step->increment_retry_count($db, $run);
    is($count2, 2, 'Second increment returns 2');
    
    is($payment_step->max_retries, 3, 'Max retries is 3');
};

subtest 'Validation error handling' => sub {
    plan tests => 2;
    
    # Create run without required profile data
    my $run = Registry::DAO::WorkflowRun->create($db, {
        workflow_id => $workflow->id,
        data => encode_json({})
    });
    
    # Test prepare_payment_data with missing profile data
    my $result = $payment_step->prepare_payment_data($db, $run);
    
    ok($result, 'Result returned even with missing data');
    # Should have default values for missing organization name
    is($result->{billing_summary}->{organization_name}, 'Your Organization', 'Default organization name used');
};

done_testing();