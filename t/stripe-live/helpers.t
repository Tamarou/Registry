#!/usr/bin/env perl
# ABOUTME: Self-test for Test::Registry::StripeConfirm and Test::Registry::StripeWebhook helpers.
# ABOUTME: Skips unless STRIPE_SECRET_KEY (sk_test_) is set; never touches live Stripe.
#
# Deviation from the issue contract (C2): the issue states these helpers are
# "exercised by t/stripe-live/paid-enrollment.t" (C3, not yet written).  The
# project CLAUDE.md requires every non-trivial helper to have an executable
# self-test, so this file exists as a deliberate bridge.  It will be superseded
# by C3 but must not be deleted -- it covers the helpers in isolation.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::StripeConnect;
use Test::Registry::StripeConfirm;
use Test::Registry::StripeWebhook;
use Test::Registry::DB;
use Test::Registry::Mojo;
use Registry::DAO::Family;
use Registry::DAO::Payment;

plan skip_all => 'STRIPE_SECRET_KEY (sk_test_) not set'
    unless Test::Registry::StripeConnect::available();

# ---------------------------------------------------------------------------
# Part 1: StripeConfirm -- live calls against the Stripe test API
# ---------------------------------------------------------------------------

subtest 'confirm with pm_card_visa succeeds' => sub {
    my $pi = Test::Registry::StripeConfirm::create_payment_intent(
        amount                    => 500,
        currency                  => 'usd',
        'payment_method_types[]'  => 'card',
    );
    like $pi->{id}, qr/^pi_/, 'create_payment_intent returns a pi_ id';

    my $confirmed = Test::Registry::StripeConfirm::confirm($pi->{id});
    is $confirmed->{status}, 'succeeded', 'pm_card_visa -> status succeeded';

    my $charge = Test::Registry::StripeConfirm::charge_for($pi->{id});
    is $charge->{amount}, 500, 'charge amount matches';
    ok $charge->{paid},        'charge.paid is true';

    note "PI created: $pi->{id}  status=$confirmed->{status}";
};

subtest 'confirm with pm_card_visa_chargeDeclined dies with card_declined' => sub {
    my $pi = Test::Registry::StripeConfirm::create_payment_intent(
        amount                    => 500,
        currency                  => 'usd',
        'payment_method_types[]'  => 'card',
    );
    like $pi->{id}, qr/^pi_/, 'second pi_ created for decline test';

    my $err = '';
    eval { Test::Registry::StripeConfirm::confirm($pi->{id}, 'pm_card_visa_chargeDeclined') };
    $err = $@;
    like $err, qr/card_declined/, 'declined confirm dies with card_declined in message';

    note "Decline PI: $pi->{id}  error=$err";
};

# ---------------------------------------------------------------------------
# Part 2: StripeWebhook -- DB-local, no Stripe network
# ---------------------------------------------------------------------------

subtest 'StripeWebhook: post_succeeded finalizes payment and deduplicates' => sub {
    # Fake key prevents accidental live Stripe calls from the webhook handler.
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_fake_for_webhook_tests';
    # STRIPE_WEBHOOK_SECRET must be set by the caller (e.g. whsec_test_fake_for_helper_tests).
    die "STRIPE_WEBHOOK_SECRET not set -- pass it on the command line\n"
        unless $ENV{STRIPE_WEBHOOK_SECRET};

    my $test_db = Test::Registry::DB->new;
    my $dao     = $test_db->db;
    my $db      = $dao->db;

    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper(dao => sub { $dao });

    # Seed minimal data -- mirrors payment-intent-webhook.t
    my $loc = $dao->create(Location => {
        name => 'Helper Studio', slug => 'helper-studio',
        address_info => {}, metadata => {},
    });
    my $prog = $dao->create(Project => {
        status => 'published', name => 'Helper Camp',
        program_type_slug => 'summer-camp', metadata => {},
    });
    my $teacher = $dao->create(User => {
        username  => 'helper_teacher', name => 'T',
        user_type => 'staff', email => 'ht@test.local',
    });
    my $session = $dao->create(Session => {
        name => 'Helper Week', start_date => '2026-01-01', end_date => '2026-12-31',
        status => 'published', capacity => 10, metadata => {},
    });
    my $event = $dao->create(Event => {
        time => '2026-06-15 09:00:00', duration => 60,
        location_id => $loc->id, project_id => $prog->id,
        teacher_id  => $teacher->id, capacity => 10, metadata => {},
    });
    $session->add_events($db, $event->id);

    my $parent = $dao->create(User => {
        username  => 'helper_parent', name => 'HP',
        user_type => 'parent', email => 'hp@test.local',
    });
    my $child = Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => 'Helper Kid', birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
    });

    my $payment = Registry::DAO::Payment->create($db, {
        user_id      => $parent->id,
        amount_cents => 500,
        status       => 'pending',
        metadata => {
            enrollment_items => [ { session_id => $session->id, child_id => $child->id } ],
            tenant_slug      => undef,
        },
    });

    my sub enrollment_count {
        scalar @{ $db->select('enrollments', '*', { payment_id => $payment->id })->hashes };
    }

    # First delivery: should finalize enrollment and mark payment completed.
    my $event_id = sprintf('evt_helper_dedup_%d_%d', time(), $$);
    Test::Registry::StripeWebhook::post_succeeded(
        $t, $payment->id, undef, 'pi_helper_fake_001',
        event_id => $event_id,
    )->status_is(200, 'first webhook delivery returns 200');

    is enrollment_count(), 1, 'enrollment created after first delivery';

    my $refreshed = Registry::DAO::Payment->find($db, { id => $payment->id });
    is $refreshed->status, 'completed', 'payment marked completed';

    # Replay the identical event_id: dedup ledger must absorb it.
    Test::Registry::StripeWebhook::post_succeeded(
        $t, $payment->id, undef, 'pi_helper_fake_002',
        event_id => $event_id,
    )->status_is(200, 'replay of same event_id returns 200');

    is enrollment_count(), 1, 'replay deduped -- still exactly one enrollment';
};

done_testing;
