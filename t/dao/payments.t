#!/usr/bin/env perl
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Payment;
use Registry::DAO::User;
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Location;
use Time::Piece;
use Mojo::JSON qw(encode_json);

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db;

# Create test tenant and set search path  
$db->query(q{
    INSERT INTO registry.tenants (id, name, slug)
    VALUES ('00000000-0000-0000-0000-000000000001', 'Test Tenant', 'test-tenant')
});
$db->query("SET search_path TO registry, public");

# Create test user
my $user = Registry::DAO::User->create($db, {
    username => 'testuser',
    email    => 'test@example.com',
    password => 'password123',
    name     => 'Test User'
});

# Create minimal test data for payments
my $session = Registry::DAO::Session->create($db, {
    name => 'Test Session'
});

my $pricing = Registry::DAO::PricingPlan->create($db, {
    session_id  => $session->id,
    plan_name   => 'Standard',
    amount_cents => 10050
});

subtest 'Create payment' => sub {
    my $payment = Registry::DAO::Payment->create($db, {
        user_id      => $user->id,
        amount_cents => 10050
    });

    ok $payment, 'Payment object created';
    isa_ok $payment, 'Registry::DAO::Payment', 'Payment is correct class';
    ok $payment->id, 'Payment created with ID';
    is $payment->user_id, $user->id, 'User ID matches';
    cmp_ok $payment->amount_cents, '==', 10050, 'Amount matches';
    is $payment->status, 'pending', 'Default status is pending';
    is $payment->currency, 'USD', 'Default currency is USD';
};

subtest 'Add line items' => sub {
    my $payment = Registry::DAO::Payment->create($db, {
        user_id      => $user->id,
        amount_cents => 20000
    });

    $payment->add_line_item($db, {
        description  => 'Child 1 - Session 1',
        amount_cents => 10000,
        quantity     => 1,
        metadata     => { child_id => 'abc123' }
    });

    $payment->add_line_item($db, {
        description  => 'Child 2 - Session 1',
        amount_cents => 10000,
        quantity     => 1,
        metadata     => { child_id => 'def456' }
    });

    my $items = $payment->line_items($db);
    is scalar(@$items), 2, 'Two line items added';
    cmp_ok $items->[0]->{amount_cents}, '==', 10000, 'First item amount correct';
    cmp_ok $items->[1]->{amount_cents}, '==', 10000, 'Second item amount correct';
};

subtest 'Calculate enrollment total' => sub {
    my $enrollment_data = {
        children => [
            { id => 1, first_name => 'Alice', last_name => 'Smith', age => 8 },
            { id => 2, first_name => 'Bob', last_name => 'Smith', age => 10 }
        ],
        session_selections => {
            1 => $session->id,
            2 => $session->id
        }
    };
    
    my $result = Registry::DAO::Payment->calculate_enrollment_total($db, $enrollment_data);
    
    cmp_ok $result->{total}, '==', 20100, 'Total calculated correctly (10050 cents * 2)';
    is scalar(@{$result->{items}}), 2, 'Two items generated';
    is $result->{items}->[0]->{description}, 'Alice Smith - Test Session', 'First item description';
    is $result->{items}->[1]->{description}, 'Bob Smith - Test Session', 'Second item description';
};

subtest 'Payment for user' => sub {
    # Create a few payments for the user
    Registry::DAO::Payment->create($db, {
        user_id      => $user->id,
        amount_cents => 5000,
        status       => 'completed'
    });

    Registry::DAO::Payment->create($db, {
        user_id      => $user->id,
        amount_cents => 7500,
        status       => 'pending'
    });
    
    my $payments = Registry::DAO::Payment->for_user($db, $user->id);
    ok scalar(@$payments) >= 2, 'At least 2 payments found for user';
    
    # Should be ordered by created_at DESC
    my $is_ordered = 1;
    for (my $i = 1; $i < @$payments; $i++) {
        # Use string comparison for timestamps to avoid numeric warnings
        if ($payments->[$i-1]->created_at lt $payments->[$i]->created_at) {
            $is_ordered = 0;
            last;
        }
    }
    ok $is_ordered, 'Payments ordered by created_at DESC';
};

# The dollars-to-cents conversion that used to live here is gone: money is
# stored and carried as integer cents end to end, so there is nothing left to
# convert and no rounding to get wrong. See t/dao/payment-amount-cents.t.

# The calls that need a real Stripe answer -- creating an intent, and Stripe
# refusing an intent id it does not know -- live in
# t/stripe-live/payment-intent-dao.t, which CI's stripe-e2e job runs.

subtest 'Process payment with no seller account fails before Stripe' => sub {
    my $payment = Registry::DAO::Payment->create($db, {
        user_id      => $user->id,
        amount_cents => 2500
    });

    my $result = $payment->process_payment($db, 'pi_never_retrieved');

    ok !$result->{success}, 'Payment fails';
    like $result->{error}, qr/no seller Stripe account/, 'for want of a seller account';
    is $payment->status, 'failed', 'Payment status updated to failed';
    is Registry::DAO::Payment->find($db, { id => $payment->id })->status, 'failed',
        'and the failure is saved';
};

done_testing();