#!/usr/bin/env perl
use v5.34.0;
use warnings;
use experimental 'signatures';
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
$db->query("SET search_path TO tenant_1, registry, public");

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
    amount      => 100.50
});

subtest 'Create payment' => sub {
    my $payment = Registry::DAO::Payment->create($db, {
        user_id  => $user->id,
        amount   => 100.50
    });
    
    ok $payment, 'Payment object created';
    isa_ok $payment, 'Registry::DAO::Payment', 'Payment is correct class';
    ok $payment->id, 'Payment created with ID';
    is $payment->user_id, $user->id, 'User ID matches';
    is $payment->amount, '100.50', 'Amount matches';
    is $payment->status, 'pending', 'Default status is pending';
    is $payment->currency, 'USD', 'Default currency is USD';
};

subtest 'Add line items' => sub {
    my $payment = Registry::DAO::Payment->create($db, {
        user_id => $user->id,
        amount  => 200
    });
    
    $payment->add_line_item($db, {
        description => 'Child 1 - Session 1',
        amount      => 100,
        quantity    => 1,
        metadata    => { child_id => 'abc123' }
    });
    
    $payment->add_line_item($db, {
        description => 'Child 2 - Session 1',
        amount      => 100,
        quantity    => 1,
        metadata    => { child_id => 'def456' }
    });
    
    my $items = $payment->line_items($db);
    is scalar(@$items), 2, 'Two line items added';
    is $items->[0]->{amount}, '100.00', 'First item amount correct';
    is $items->[1]->{amount}, '100.00', 'Second item amount correct';
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
    
    is $result->{total}, 201, 'Total calculated correctly (100.50 * 2)';
    is scalar(@{$result->{items}}), 2, 'Two items generated';
    is $result->{items}->[0]->{description}, 'Alice Smith - Test Session', 'First item description';
    is $result->{items}->[1]->{description}, 'Bob Smith - Test Session', 'Second item description';
};

subtest 'Payment for user' => sub {
    # Create a few payments for the user
    Registry::DAO::Payment->create($db, {
        user_id => $user->id,
        amount  => 50,
        status  => 'completed'
    });
    
    Registry::DAO::Payment->create($db, {
        user_id => $user->id,
        amount  => 75,
        status  => 'pending'
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

# Skip Stripe-specific tests if API key not set or SSL not available
SKIP: {
    skip "STRIPE_SECRET_KEY not set", 2 unless $ENV{STRIPE_SECRET_KEY};

    # Test if SSL is available for HTTPS requests
    my $ssl_available = eval {
        require IO::Socket::SSL;
        IO::Socket::SSL->VERSION >= 2.009;
    };
    skip "IO::Socket::SSL 2.009+ required for Stripe API calls", 2 unless $ssl_available;
    
    subtest 'Create payment intent' => sub {
        my $payment = Registry::DAO::Payment->create($db, {
            user_id => $user->id,
            amount  => 50
        });
        
        my $intent_data = eval {
            $payment->create_payment_intent($db, {
                description => 'Test Payment',
                receipt_email => $user->email
            })
        };
        
        if ($@) {
            diag "Stripe error: $@";
            skip "Stripe API error", 3;
        }
        
        ok $intent_data->{client_secret}, 'Client secret returned';
        ok $intent_data->{payment_intent_id}, 'Payment intent ID returned';
        
        # Reload payment to check if intent ID was saved
        $payment = Registry::DAO::Payment->new(id => $payment->id)->load($db);
        is $payment->stripe_payment_intent_id, $intent_data->{payment_intent_id}, 'Intent ID saved to payment';
    };
    
    subtest 'Process payment' => sub {
        my $payment = Registry::DAO::Payment->create($db, {
            user_id => $user->id,
            amount  => 25
        });
        
        # Would need a real payment intent ID from Stripe to test this properly
        # For now, just test the error handling
        my $result = $payment->process_payment($db, 'invalid_intent_id');
        
        ok !$result->{success}, 'Invalid intent fails';
        ok $result->{error}, 'Error message returned';
        is $payment->status, 'failed', 'Payment status updated to failed';
    };
}

done_testing();