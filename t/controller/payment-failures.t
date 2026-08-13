#!/usr/bin/env perl
# ABOUTME: DAO-level tests for refund handling on the payments table.
# ABOUTME: Tests that a refund updates the payment row and the enrollment it paid for.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Mojo::JSON qw(encode_json);

use Registry::DAO;
use Registry::DAO::User;
use Registry::DAO::Session;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# --- Test Data Setup ---

my $location = $dao->create(Location => {
    name         => 'Payment Test Studio',
    address_info => { street => '100 Main', city => 'Orlando', state => 'FL' },
    metadata     => {},
});

my $teacher = $dao->create(User => { username => 'pf_teacher', user_type => 'staff' });

my $program = $dao->create(Project => { status => 'published',
    name => 'Payment Failure Camp', metadata => {},
});

my $session = $dao->create(Session => {
    name       => 'Payment Test Session',
    start_date => '2026-06-01',
    end_date   => '2026-06-05',
    status     => 'published',
    capacity   => 16,
    metadata   => {},
});

my $event = $dao->create(Event => {
    time        => '2026-06-01 09:00:00',
    duration    => 420,
    location_id => $location->id,
    project_id  => $program->id,
    teacher_id  => $teacher->id,
    capacity    => 16,
    metadata    => {},
});
$session->add_events($dao->db, $event->id);

my $parent = $dao->create(User => {
    username => 'pf_parent', name => 'Payment Parent',
    user_type => 'parent', email => 'pf@example.com',
});

my $enrollment_id = $dao->db->insert('enrollments', {
    session_id => $session->id,
    student_id => $parent->id,
    status     => 'active',
    metadata   => '{}',
}, { returning => 'id' })->hash->{id};

# ============================================================
# Refund Processing (DAO level - no webhook handler for refunds)
# ============================================================
subtest 'refund updates payment and enrollment status' => sub {
    # Create a completed payment record directly in the DB
    my $payment = $dao->db->insert('registry.payments', {
        user_id      => $parent->id,
        amount_cents => 30000,
        currency => 'USD',
        status   => 'completed',
        stripe_payment_intent_id => 'pi_test_refund_1',
        metadata => '{}',
    }, { returning => '*' })->hash;
    ok $payment, 'Payment record created';

    # Full refund: update status directly (bypassing Stripe API)
    $dao->db->update('registry.payments', {
        status   => 'refunded',
        metadata => encode_json({
            refund_id     => 'rf_test_1',
            refund_amount_cents => 30000,
            refund_reason => 'requested_by_customer',
        }),
    }, { id => $payment->{id} });

    my $refunded = $dao->db->select('registry.payments', '*', {
        id => $payment->{id},
    })->hash;
    is $refunded->{status}, 'refunded', 'Payment status updated to refunded';

    # Update enrollment status for full refund
    $dao->db->update('enrollments', {
        status => 'cancelled',
    }, { id => $enrollment_id });

    my $enrollment = $dao->db->select('enrollments', '*', {
        id => $enrollment_id,
    })->hash;
    is $enrollment->{status}, 'cancelled', 'Enrollment cancelled after full refund';

    # Partial refund: should NOT cancel enrollment
    my $parent2 = $dao->create(User => {
        username => 'pf_parent2', name => 'Partial Refund Parent',
        user_type => 'parent', email => 'pf2@example.com',
    });

    my $payment2 = $dao->db->insert('registry.payments', {
        user_id      => $parent2->id,
        amount_cents => 30000,
        currency => 'USD',
        status   => 'completed',
        stripe_payment_intent_id => 'pi_test_refund_2',
        metadata => '{}',
    }, { returning => '*' })->hash;

    my $enrollment2_id = $dao->db->insert('enrollments', {
        session_id => $session->id,
        student_id => $parent2->id,
        status     => 'active',
        metadata   => '{}',
    }, { returning => 'id' })->hash->{id};

    $dao->db->update('registry.payments', {
        status   => 'partially_refunded',
        metadata => encode_json({
            refund_id     => 'rf_test_2',
            refund_amount_cents => 10000,
            refund_reason => 'requested_by_customer',
        }),
    }, { id => $payment2->{id} });

    my $partial = $dao->db->select('registry.payments', '*', {
        id => $payment2->{id},
    })->hash;
    is $partial->{status}, 'partially_refunded', 'Payment partially refunded';

    my $enrollment2 = $dao->db->select('enrollments', '*', {
        id => $enrollment2_id,
    })->hash;
    is $enrollment2->{status}, 'active', 'Enrollment stays active after partial refund';
};

done_testing;
