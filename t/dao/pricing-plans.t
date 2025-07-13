#!/usr/bin/env perl
use v5.34.0;
use warnings;
use utf8;
use experimental qw(signatures);

use Test::More;
use Test::Exception;
use Test::Deep;

use lib qw(lib t/lib);
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry::DAO::PricingPlan;
use Registry::DAO::Event;

# Setup test database
my $t  = Test::Registry::DB->new;
my $db = $t->db;

# Create a test tenant
my $tenant = Test::Registry::Fixtures::create_tenant($db, {
    name => 'Test Organization',
    slug => 'test-org',
});

# Switch to tenant schema
$db->schema($tenant->slug);

# Create test data
my $location = Test::Registry::Fixtures::create_location($db, {
    name => 'Test School',
});

my $project = Test::Registry::Fixtures::create_project($db, {
    name => 'Test Program',
});

my $session = Test::Registry::Fixtures::create_session($db, {
    name => 'Summer 2024',
    start_date => '2024-06-01',
    end_date => '2024-08-31',
});

subtest 'Create pricing plan' => sub {
    my $plan = Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id,
        plan_name => 'Standard Rate',
        plan_type => 'standard',
        amount => 500.00,
        currency => 'USD',
    });
    
    ok($plan, 'Pricing plan created');
    is($plan->plan_name, 'Standard Rate', 'Plan name set');
    is($plan->plan_type, 'standard', 'Plan type set');
    is($plan->amount, 500.00, 'Amount set');
    is($plan->currency, 'USD', 'Currency set');
    ok(!$plan->installments_allowed, 'Installments not allowed by default');
};

subtest 'Create early bird plan' => sub {
    my $plan = Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id,
        plan_name => 'Early Bird Special',
        plan_type => 'early_bird',
        amount => 450.00,
        requirements => {
            early_bird_cutoff_date => '2024-05-01'
        }
    });
    
    ok($plan, 'Early bird plan created');
    is($plan->plan_type, 'early_bird', 'Plan type is early_bird');
    is($plan->amount, 450.00, 'Discounted amount set');
    is($plan->requirements->{early_bird_cutoff_date}, '2024-05-01', 'Cutoff date stored');
};

subtest 'Create family plan' => sub {
    my $plan = Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id,
        plan_name => 'Family Discount',
        plan_type => 'family',
        amount => 425.00,
        requirements => {
            min_children => 2,
            percentage_discount => 15
        }
    });
    
    ok($plan, 'Family plan created');
    is($plan->requirements->{min_children}, 2, 'Minimum children requirement set');
    is($plan->requirements->{percentage_discount}, 15, 'Discount percentage set');
};

subtest 'Installment plans' => sub {
    my $plan = Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id,
        plan_name => 'Payment Plan',
        plan_type => 'standard',
        amount => 600.00,
        installments_allowed => 1,
        installment_count => 3
    });
    
    ok($plan->installments_allowed, 'Installments allowed');
    is($plan->installment_count, 3, 'Three installments');
    is($plan->installment_amount, 200.00, 'Installment amount calculated correctly');
    
    # Test invalid installment configuration
    dies_ok {
        Registry::DAO::PricingPlan->create($db, {
            session_id => $session->id,
            plan_name => 'Bad Plan',
            amount => 100,
            installments_allowed => 1,
            installment_count => 1  # Should be > 1
        });
    } 'Dies when installment count is 1';
};

subtest 'Get pricing plans for session' => sub {
    # Clear existing plans
    $db->delete('pricing_plans', { session_id => $session->id });
    
    # Create multiple plans
    Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id,
        plan_name => 'Standard',
        plan_type => 'standard',
        amount => 500
    });
    
    Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id,
        plan_name => 'Early Bird',
        plan_type => 'early_bird',
        amount => 450,
        requirements => { early_bird_cutoff_date => '2024-05-01' }
    });
    
    my $plans = Registry::DAO::PricingPlan->get_pricing_plans($db, $session->id);
    is(@$plans, 2, 'Two plans retrieved');
    
    my @types = sort map { $_->plan_type } @$plans;
    is_deeply(\@types, ['early_bird', 'standard'], 'Both plan types present');
};

subtest 'Calculate price with requirements' => sub {
    my $early_bird = Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id,
        plan_name => 'Early Bird',
        plan_type => 'early_bird',
        amount => 400,
        requirements => { early_bird_cutoff_date => '2024-05-01' }
    });
    
    # Test before cutoff
    my $price = $early_bird->calculate_price({ date => '2024-04-15' });
    is($price, 400, 'Early bird price available before cutoff');
    
    # Test after cutoff
    $price = $early_bird->calculate_price({ date => '2024-05-15' });
    is($price, undef, 'Early bird price not available after cutoff');
    
    # Test family plan
    my $family = Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id,
        plan_name => 'Family',
        plan_type => 'family',
        amount => 450,
        requirements => { min_children => 2 }
    });
    
    $price = $family->calculate_price({ child_count => 1 });
    is($price, undef, 'Family price not available with 1 child');
    
    $price = $family->calculate_price({ child_count => 2 });
    is($price, 450, 'Family price available with 2 children');
};

subtest 'Get best price' => sub {
    # Clear and create fresh plans
    $db->delete('pricing_plans', { session_id => $session->id });
    
    Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id,
        plan_name => 'Standard',
        plan_type => 'standard',
        amount => 500
    });
    
    Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id,
        plan_name => 'Early Bird',
        plan_type => 'early_bird',
        amount => 450,
        requirements => { early_bird_cutoff_date => '2024-12-31' }
    });
    
    Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id,
        plan_name => 'Family',
        plan_type => 'family',
        amount => 425,
        requirements => { min_children => 2 }
    });
    
    # Test different contexts
    my $best = Registry::DAO::PricingPlan->get_best_price($db, $session->id, {
        date => '2024-01-01',
        child_count => 1
    });
    is($best, 450, 'Early bird is best price for single child early');
    
    $best = Registry::DAO::PricingPlan->get_best_price($db, $session->id, {
        date => '2024-01-01',
        child_count => 2
    });
    is($best, 425, 'Family plan is best price for multiple children');
    
    $best = Registry::DAO::PricingPlan->get_best_price($db, $session->id, {
        date => '2025-01-01',
        child_count => 1
    });
    is($best, 500, 'Standard price when no special plans apply');
};

subtest 'Session integration' => sub {
    my $plans = $session->pricing_plans($db);
    ok($plans, 'Got pricing plans from session');
    isa_ok($plans, 'ARRAY', 'Returns array ref');
    
    my $best = $session->get_best_price($db, { date => '2024-01-01' });
    ok(defined $best, 'Got best price from session');
};

subtest 'Formatted price' => sub {
    my $plan = Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id,
        plan_name => 'Test',
        amount => 123.45,
        currency => 'USD'
    });
    
    is($plan->formatted_price, '$123.45', 'USD formatting correct');
    
    $plan = Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id,
        plan_name => 'Test EUR',
        amount => 100.00,
        currency => 'EUR'
    });
    
    is($plan->formatted_price, '100.00 EUR', 'EUR formatting correct');
};

done_testing;