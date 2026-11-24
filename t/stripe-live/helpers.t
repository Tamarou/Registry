#!/usr/bin/env perl
# ABOUTME: Self-test for Test::Registry::StripeConfirm and Test::Registry::StripeWebhook helpers.
# ABOUTME: Skips unless STRIPE_SECRET_KEY (sk_test_) is set, signs its own webhooks, and never touches live Stripe.
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
use Registry::Service::Stripe;

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

subtest 'live key makes the suite refuse to run' => sub {
    local $ENV{STRIPE_SECRET_KEY} = 'sk' . '_live_' . 'x' x 24;
    my $sent = 0;
    no warnings 'redefine';
    local *Mojo::UserAgent::start = sub { $sent++; die "request sent\n" };

    ok !Test::Registry::StripeConnect::available(),
        'the skip guard reports no usable key, so every live file skips';
    my %calls = (
        ready_account         => sub { Test::Registry::StripeConnect::ready_account() },
        create_payment_intent => sub {
            Test::Registry::StripeConfirm::create_payment_intent( amount => 500, currency => 'usd' );
        },
        confirm            => sub { Test::Registry::StripeConfirm::confirm( 'pi_x', undef, 'acct_x' ) },
        charge_for_settled => sub { Test::Registry::StripeConfirm::charge_for_settled( 'pi_x', 'acct_x' ) },
        'Service::Stripe from_env' => sub { Registry::Service::Stripe->from_env },
    );
    for my $name ( sort keys %calls ) {
        ok !eval { $calls{$name}->(); 1 }, "$name dies";
        unlike $@, qr/request sent/, "$name dies before any request";
    }
    is $sent, 0, 'and no request was sent';
};

# ---------------------------------------------------------------------------
# Part 2: StripeWebhook -- DB-local, no Stripe network
# ---------------------------------------------------------------------------

subtest 'StripeWebhook: post_succeeded finalizes payment and deduplicates' => sub {
    # Fake key prevents accidental live Stripe calls from the webhook handler.
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_fake_for_webhook_tests';
    # The events are self-signed, so the secret is a local value, not Stripe's.
    local $ENV{STRIPE_WEBHOOK_SECRET} = 'whsec_local_helper_tests';

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

    # Only the intent Registry stored settles a payment.
    $db->update('payments', { stripe_payment_intent_id => 'pi_helper_fake_001' },
        { id => $payment->id });

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

# ---------------------------------------------------------------------------
# Part 3: confirm and poll on a connected account -- a direct charge lives
# there, so every call names it in Stripe-Account.
# ---------------------------------------------------------------------------

subtest 'confirm and poll run on the connected account' => sub {
    my $acct = Test::Registry::StripeConnect::ready_account();

    my $pi = Test::Registry::StripeConfirm::create_payment_intent(
        stripe_account           => $acct,
        amount                   => 1000,
        currency                 => 'usd',
        application_fee_amount   => 25,
        'payment_method_types[]' => 'card',
    );
    like $pi->{id}, qr/^pi_/, 'an intent on the connected account';

    my $confirmed = Test::Registry::StripeConfirm::confirm( $pi->{id}, undef, $acct );
    is $confirmed->{status}, 'succeeded', 'confirm reaches it with the account named';

    my $charge = Test::Registry::StripeConfirm::charge_for_settled( $pi->{id}, $acct );
    is $charge->{amount}, 1000, 'charge_for_settled finds its charge there';
    like $charge->{application_fee}, qr/^fee_/, 'and waits for the application fee';
    ok !$charge->{transfer}, 'with no transfer, since nothing is moved to the account';

    ok !eval { Test::Registry::StripeConfirm::charge_for( $pi->{id} ); 1 },
        'without the account the intent is not found on the platform';
};

done_testing;
