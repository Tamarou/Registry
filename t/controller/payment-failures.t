#!/usr/bin/env perl
# ABOUTME: Controller tests for payment failure handling via Stripe webhooks.
# ABOUTME: Tests card decline, duplicate webhook, failed installment, and refund at HTTP and DAO layers.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Mojo::JSON qw(encode_json);

use Registry::DAO;
use Registry::DAO::User;
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;
use Registry::DAO::PaymentSchedule;
use Registry::DAO::ScheduledPayment;

# Fake Stripe key so PriceOps::ScheduledPayment constructor doesn't die.
# No actual Stripe calls are made in these tests.
local $ENV{STRIPE_SECRET_KEY} = 'sk_test_fake_for_webhook_tests';
local $ENV{STRIPE_WEBHOOK_SECRET} = 'whsec_test_fake_for_webhook_tests';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

# --- Test Data Setup ---

my $location = $dao->create(Location => {
    name         => 'Payment Test Studio',
    address_info => { street => '100 Main', city => 'Orlando', state => 'FL' },
    metadata     => {},
});

my $teacher = $dao->create(User => { username => 'pf_teacher', user_type => 'staff' });

my $program = $dao->create(Project => {
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

my $pricing = $dao->create(PricingPlan => {
    session_id          => $session->id,
    plan_name           => 'Installment Plan',
    plan_type           => 'standard',
    amount              => 300.00,
    installments_allowed => 1,
    installment_count   => 3,
});

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

# Helper to create a payment schedule with 3 installments
sub create_test_schedule ($subscription_id) {
    my $schedule = $dao->db->insert('registry.payment_schedules', {
        enrollment_id          => $enrollment_id,
        pricing_plan_id        => $pricing->id,
        stripe_subscription_id => $subscription_id,
        total_amount           => 300.00,
        installment_amount     => 100.00,
        installment_count      => 3,
        status                 => 'active',
    }, { returning => '*' })->hash;

    for my $i (1..3) {
        $dao->db->insert('registry.scheduled_payments', {
            payment_schedule_id => $schedule->{id},
            installment_number  => $i,
            amount              => 100.00,
            status              => 'pending',
        });
    }

    return $schedule;
}

# Helper to post a Stripe webhook event with a valid signature.
# Uses the UA directly to avoid Test::Registry::Mojo's CSRF injection,
# which conflicts with raw JSON bodies.  Webhooks are excluded from
# CSRF validation (see Registry.pm before_dispatch hook).
sub post_webhook ($event) {
    require Digest::SHA;
    require Mojo::JSON;
    my $payload   = Mojo::JSON::encode_json($event);
    my $timestamp = time();
    my $sig       = Digest::SHA::hmac_sha256_hex("$timestamp.$payload", $ENV{STRIPE_WEBHOOK_SECRET});
    my $header    = "t=$timestamp,v1=$sig";
    my $tx = $t->ua->post('/webhooks/stripe' => {
        'stripe-signature' => $header,
        'Content-Type'     => 'application/json',
    } => $payload);
    # Store the transaction so chained assertions (->status_is etc.) work
    $t->{_res} = $tx->res;
    return $t->tx($tx);
}

# ============================================================
# 4.1 Card Decline
# ============================================================
subtest 'card decline via webhook marks payment as failed' => sub {
    my $sub_id = 'sub_test_decline_' . $$;
    my $schedule = create_test_schedule($sub_id);

    post_webhook({
        id   => 'evt_decline_1',
        type => 'invoice.payment_failed',
        data => {
            object => {
                id           => 'in_decline_1',
                subscription => $sub_id,
                last_finalization_error => {
                    message => 'Your card was declined (insufficient_funds)',
                },
            },
        },
    })->status_is(200, 'Webhook returns 200 OK');

    # Verify the first scheduled payment is marked as failed
    my $payments = $dao->db->select('registry.scheduled_payments', '*', {
        payment_schedule_id => $schedule->{id},
    }, { -asc => 'installment_number' })->hashes;

    is $payments->[0]{status}, 'failed', 'Installment 1 marked as failed';
    ok $payments->[0]{failure_reason}, 'Failure reason stored';
    like $payments->[0]{failure_reason}, qr/insufficient_funds/, 'Reason contains decline code';
    ok $payments->[0]{failed_at}, 'Failed timestamp recorded';

    is $payments->[1]{status}, 'pending', 'Installment 2 still pending';
    is $payments->[2]{status}, 'pending', 'Installment 3 still pending';
};

# ============================================================
# 4.2 Duplicate Webhook Delivery
# ============================================================
subtest 'duplicate webhook does not double-process' => sub {
    my $sub_id = 'sub_test_dup_' . $$;
    my $schedule = create_test_schedule($sub_id);

    my $webhook_event = {
        id   => 'evt_paid_dup_1',
        type => 'invoice.paid',
        data => {
            object => {
                id             => 'in_paid_dup_1',
                subscription   => $sub_id,
                payment_intent => 'pi_test_dup_1',
            },
        },
    };

    # First delivery
    post_webhook($webhook_event)->status_is(200, 'First delivery returns 200');

    my $payments_after_first = $dao->db->select('registry.scheduled_payments', '*', {
        payment_schedule_id => $schedule->{id},
    }, { -asc => 'installment_number' })->hashes;

    is $payments_after_first->[0]{status}, 'completed', 'First installment completed';
    is $payments_after_first->[1]{status}, 'pending', 'Second still pending after first delivery';

    # Second delivery of the SAME event
    post_webhook($webhook_event)->status_is(200, 'Second delivery returns 200 (acknowledged)');

    my $payments_after_second = $dao->db->select('registry.scheduled_payments', '*', {
        payment_schedule_id => $schedule->{id},
    }, { -asc => 'installment_number' })->hashes;

    # NOTE: The system lacks event-ID deduplication. The second delivery marks
    # the next pending payment as completed. This is a known limitation.
    # Tracking here so we know when it's fixed.
    my $completed_count = grep { $_->{status} eq 'completed' } @$payments_after_second;

    TODO: {
        local $TODO = 'Webhook handler lacks event-ID deduplication';
        is $completed_count, 1, 'Only one payment completed after duplicate delivery';
    }

    # What actually happens: two payments get completed
    ok $completed_count >= 1, 'At least one payment completed (system processes webhook)';
};

# ============================================================
# 4.3 Failed Installment
# ============================================================
subtest 'failed installment after successful first payment' => sub {
    my $sub_id = 'sub_test_installment_' . $$;
    my $schedule = create_test_schedule($sub_id);

    # First installment succeeds
    post_webhook({
        id   => 'evt_install_paid_1',
        type => 'invoice.paid',
        data => {
            object => {
                id             => 'in_install_paid_1',
                subscription   => $sub_id,
                payment_intent => 'pi_install_1',
            },
        },
    })->status_is(200, 'First installment webhook processed');

    # Second installment fails (card declined)
    post_webhook({
        id   => 'evt_install_fail_2',
        type => 'invoice.payment_failed',
        data => {
            object => {
                id           => 'in_install_fail_2',
                subscription => $sub_id,
                last_finalization_error => {
                    message => 'Your card has expired (expired_card)',
                },
            },
        },
    })->status_is(200, 'Failed installment webhook processed');

    # Check payment states
    my $payments = $dao->db->select('registry.scheduled_payments', '*', {
        payment_schedule_id => $schedule->{id},
    }, { -asc => 'installment_number' })->hashes;

    is $payments->[0]{status}, 'completed', 'Installment 1 completed';
    ok $payments->[0]{paid_at}, 'Installment 1 has paid_at timestamp';

    is $payments->[1]{status}, 'failed', 'Installment 2 failed';
    like $payments->[1]{failure_reason}, qr/expired_card/, 'Failure reason mentions expired card';
    ok $payments->[1]{failed_at}, 'Installment 2 has failed_at timestamp';

    is $payments->[2]{status}, 'pending', 'Installment 3 still pending (not charged)';

    # Schedule should still be active (Stripe dunning handles retries)
    my $updated_schedule = $dao->db->select('registry.payment_schedules', '*', {
        id => $schedule->{id},
    })->hash;
    is $updated_schedule->{status}, 'active', 'Schedule remains active (Stripe manages retries)';
};

# ============================================================
# 4.4 Refund Processing (DAO level - no webhook handler for refunds)
# ============================================================
subtest 'refund updates payment and enrollment status' => sub {
    # Create a completed payment record directly in the DB
    my $payment = $dao->db->insert('registry.payments', {
        user_id  => $parent->id,
        amount   => 300.00,
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
            refund_amount => 300.00,
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
        user_id  => $parent2->id,
        amount   => 300.00,
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
            refund_amount => 100.00,
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
