# ABOUTME: Gated real-Stripe test suite proving invariants I1-I7 for the money path.
# ABOUTME: Requires STRIPE_SECRET_KEY (sk_test_) + STRIPE_WEBHOOK_SECRET; skips silently otherwise.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::StripeConnect;
use Test::Registry::StripeConfirm;
use Test::Registry::StripeWebhook;
use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::Async qw( settle );

use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Family;
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Location;
use Registry::DAO::Payment;
use Registry::DAO::WorkflowSteps::Payment;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;

plan skip_all => 'STRIPE_SECRET_KEY (sk_test_) not set'
    unless Test::Registry::StripeConnect::available();

# Self-sign synthetic webhook events with a local secret.
# DO NOT localise STRIPE_SECRET_KEY -- the real key must reach the production
# create_payment_intent call inside each subtest that drives the workflow step.
local $ENV{STRIPE_WEBHOOK_SECRET} = 'whsec_c3_local';

# ---------------------------------------------------------------------------
# 1. Provision a fresh tenant and build all fixtures in the tenant schema.
#    Structure mirrors t/integration/tenant-paid-enrollment.t exactly.
# ---------------------------------------------------------------------------

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $slug = 'c3_paid_' . $$;

my $admin = Registry::DAO::User->create($db, {
    username  => "c3_admin_$$",
    email     => "c3_admin_$$\@test.example",
    name      => 'C3 Admin',
    user_type => 'admin',
});

my $tenant = Registry::DAO::Tenant->provision($db, {
    name  => "C3 Paid Tenant $$",
    slug  => $slug,
    users => [ $admin ],
});
ok $tenant, 'tenant provisioned';

# Tenant-schema connection
my $tdao = Registry::DAO->new(url => $test_db->uri, schema => $slug);
my $tdb  = $tdao->db;

# --- fixtures in the tenant schema ---

my $location = Registry::DAO::Location->create($tdb, {
    name         => 'C3 Studio',
    address_info => { street_address => '1 C3 Blvd', city => 'T', state => 'TX', postal_code => '78701' },
    metadata     => {},
});

my $teacher = Registry::DAO::User->create($tdb, {
    name      => 'C3 Teacher',
    username  => "c3_teacher_$$",
    email     => "c3_teacher_$$\@test.com",
    user_type => 'staff',
});

my $project = Registry::DAO::Project->create($tdb, {
    name              => 'C3 Summer Camp',
    slug              => "c3_camp_$$",
    status            => 'published',
    program_type_slug => 'summer-camp',
    metadata          => {},
});

my $event = Registry::DAO::Event->create($tdb, {
    time        => '2026-08-01 10:00:00',
    duration    => 120,
    location_id => $location->id,
    project_id  => $project->id,
    teacher_id  => $teacher->id,
    capacity    => 20,
    metadata    => {},
});

# $150.00 paid session -- 2% fee = 300 cents
my $PLAN_AMOUNT = 150.00;
my $EXPECTED_FEE_CENTS = 300;  # 2% of 15000 cents

my $session = Registry::DAO::Session->create($tdb, {
    name       => 'C3 Week',
    start_date => '2026-08-01',
    end_date   => '2026-08-07',
    status     => 'published',
    capacity   => 20,
    metadata   => {},
});
$session->add_events($tdb, $event->id);
Registry::DAO::PricingPlan->create($tdb, {
    session_id => $session->id,
    plan_name  => 'Standard',
    plan_type  => 'standard',
    amount     => $PLAN_AMOUNT,
});

# Parent + child in the tenant schema
my $parent = Registry::DAO::User->create($tdb, {
    email     => "c3_parent_$$\@example.com",
    username  => "c3_parent_$$",
    name      => 'C3 Parent',
    user_type => 'parent',
});

my $child = Registry::DAO::Family->add_child($tdb, $parent->id, {
    child_name        => 'C3 Child',
    birth_date        => '2018-03-15',
    grade             => '3',
    medical_info      => {},
    emergency_contact => { name => 'Emergency', phone => '555-0199' },
});

# Minimal workflow with a Payment step and a completion step
my $workflow = Registry::DAO::Workflow->create($tdb, {
    name        => 'C3 Test Workflow',
    slug        => "c3-workflow-$$",
    description => 'Real-Stripe end-to-end workflow for I1-I7',
});

my $payment_step_row = Registry::DAO::WorkflowStep->create($tdb, {
    workflow_id => $workflow->id,
    slug        => 'payment',
    class       => 'Registry::DAO::WorkflowSteps::Payment',
    description => 'Payment processing step',
});

Registry::DAO::WorkflowStep->create($tdb, {
    workflow_id => $workflow->id,
    slug        => 'complete',
    class       => 'Registry::DAO::WorkflowStep',
    description => 'Completion step',
    depends_on  => $payment_step_row->id,
});

$workflow->update($tdb, { first_step => 'payment' }, { id => $workflow->id });

sub make_e2e_run {
    my $run = $workflow->new_run($tdb);
    $run->update_data($tdb, {
        user_id            => $parent->id,
        children           => [ {
            id         => $child->id,
            first_name => 'C3',
            last_name  => 'Child',
            birth_date => '2018-03-15',
            grade      => '3',
        } ],
        session_selections => { $child->id => $session->id },
        enrollment_items   => [ { child_id => $child->id, session_id => $session->id } ],
        __tenant_slug      => $slug,
    });
    return $run;
}

sub get_payment_step {
    return $workflow->get_step($tdb, { slug => 'payment' });
}

# Every process() call in this file is a paid-enrollment path with a real Stripe
# key set, so the step always defers (see Payment.pm's contract comment). Assert
# that before settling rather than after: a Mojo::Promise is a blessed hashref,
# so reading $result->{errors} off one yields undef and every assertion in the
# subtest passes or fails for the wrong reason instead of erroring.
sub process_payment_step ( $step, $run ) {
    my $result = $step->process($tdb, { agreeTerms => 1 }, $run);
    isa_ok $result, 'Mojo::Promise', 'payment step result';
    return settle($result);
}

# ---------------------------------------------------------------------------
# 2. Build the Mojo test app for webhook subtests (I4).
#    Mirrors t/controller/payment-intent-webhook.t exactly.
# ---------------------------------------------------------------------------

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

# ---------------------------------------------------------------------------
# 3. Obtain both Stripe test accounts.
#    unready_account() returns immediately; ready_account() polls up to 90s.
# ---------------------------------------------------------------------------

note 'Fetching unready Stripe test account (instant)...';
my $unready_acct = Test::Registry::StripeConnect::unready_account();
like $unready_acct, qr/^acct_/, 'unready account id obtained';

note 'Waiting for charges_enabled on ready Stripe test account (up to 90s)...';
my $ready_acct = Test::Registry::StripeConnect::ready_account();
like $ready_acct, qr/^acct_/, 'ready account id obtained';

# ---------------------------------------------------------------------------
# I5: Gate -- unready tenant blocks enrollment, zero rows, no Stripe call.
#     Runs first, while the tenant still has no stripe fields set.
# ---------------------------------------------------------------------------

subtest 'I5: unready-tenant gate fires, no payment rows, Stripe never called' => sub {
    # Point the tenant at the unready account so stripe_connect_account_id is set
    # but stripe_charges_enabled remains FALSE -- gate must fire.
    $db->query(
        'UPDATE registry.tenants SET stripe_connect_account_id = $1 WHERE slug = $2',
        $unready_acct, $slug,
    );

    ok !$tenant->stripe_connect_ready,
        'precondition: tenant stripe_connect_ready is false (charges_enabled=FALSE)';

    my $run  = make_e2e_run();
    my $step = get_payment_step();
    my $result = process_payment_step($step, $run);

    ok $result->{errors}, 'I5: gate returned errors';
    like $result->{errors}[0], qr/not yet available/i,
        'I5: error message mentions unavailability';
    is $result->{next_step}, $step->id, 'I5: stays on payment step (not advanced)';

    my $tenant_count = $tdb->select('payments', ['id'], { user_id => $parent->id })->hashes->size;
    is $tenant_count, 0, 'I5: zero payment rows in tenant schema';

    my $registry_count = $db->select('registry.payments', ['id'], { user_id => $parent->id })->hashes->size;
    is $registry_count, 0, 'I5: zero payment rows in registry schema (Stripe never called)';
};

# ---------------------------------------------------------------------------
# 4. Mark the tenant ready with the real charges_enabled Stripe account.
# ---------------------------------------------------------------------------

$db->query(
    'UPDATE registry.tenants SET stripe_connect_account_id = $1, stripe_charges_enabled = TRUE, stripe_details_submitted = TRUE WHERE slug = $2',
    $ready_acct, $slug,
);

# Link the tenant to the seeded 2% revenue-share plan so the fee resolver
# applies a 2% fee at charge time. Same UPDATE as tenant-paid-enrollment.t.
$db->query(q{
    UPDATE registry.tenants SET platform_pricing_plan_id = (
        SELECT id FROM registry.pricing_plans
         WHERE plan_scope = 'tenant'
           AND pricing_model_type = 'percentage'
           AND metadata->>'default' IS DISTINCT FROM 'true'
         ORDER BY created_at
         LIMIT 1
    ) WHERE slug = ?
}, $slug);

# Shared state populated by I1+I2 and consumed by I4 and I6.
my ($main_payment_id, $main_pi_id, $charge_fee_id, $charge_transfer_id);

# ---------------------------------------------------------------------------
# I1+I2: Real Stripe destination charge, correct routing and fee.
# ---------------------------------------------------------------------------

subtest 'I1+I2: destination charge routes to ready account with correct 2% fee' => sub {
    my $run  = make_e2e_run();
    my $step = get_payment_step();
    my $result = process_payment_step($step, $run);

    ok !$result->{errors}, 'I1/I2: no gate error for ready tenant'
        or diag explain $result->{errors};

    $main_payment_id = $result->{data}{payment_id};
    ok $main_payment_id, 'I1/I2: payment_id present in result';

    my $payment = Registry::DAO::Payment->find($tdb, { id => $main_payment_id });
    $main_pi_id = $payment->stripe_payment_intent_id;
    like $main_pi_id, qr/^pi_/, 'I1/I2: stripe_payment_intent_id is a real pi_ id';

    # Confirm the intent server-side (browser-confirmation stand-in)
    my $confirmed = Test::Registry::StripeConfirm::confirm($main_pi_id);
    is $confirmed->{status}, 'succeeded', 'I1/I2: intent confirmed as succeeded';

    # Wait for the destination-charge side effects (application_fee + transfer)
    # to attach; they are eventually consistent, a few seconds behind the charge.
    my $charge = Test::Registry::StripeConfirm::charge_for_settled($main_pi_id);

    is $charge->{transfer_data}{destination}, $ready_acct,
        'I1: charge.transfer_data.destination is the ready account';
    is $charge->{application_fee_amount}, $EXPECTED_FEE_CENTS,
        "I2: application_fee_amount == $EXPECTED_FEE_CENTS cents (2% of \$150.00)";

    # Save charge fields for I6 refund assertions
    $charge_fee_id      = $charge->{application_fee};
    $charge_transfer_id = $charge->{transfer};
    ok $charge_fee_id,      'I2: charge carries an application_fee id';
    ok $charge_transfer_id, 'I2: charge carries a transfer id';
};

# ---------------------------------------------------------------------------
# I4: Webhook dedup -- first delivery finalizes; replay is absorbed at 200.
# ---------------------------------------------------------------------------

subtest 'I4: webhook dedup -- first delivery enrolls, same event_id replay is a no-op' => sub {
    my $evt1 = sprintf('evt_c3_%d_%d_1', time(), $$);

    Test::Registry::StripeWebhook::post_succeeded(
        $t, $main_payment_id, $slug, $main_pi_id,
        event_id => $evt1,
    )->status_is(200, 'I4: first webhook delivery returns 200');

    my $enrs = $tdb->select('enrollments', '*', { payment_id => $main_payment_id })->hashes;
    is scalar @$enrs, 1, 'I4: exactly one enrollment after first webhook';
    is $enrs->[0]{status}, 'active', 'I4: enrollment status is active';

    my $pay = Registry::DAO::Payment->find($tdb, { id => $main_payment_id });
    is $pay->status, 'completed', 'I4: payment marked completed after webhook';

    # Replay the identical event_id: dedup ledger must absorb it.
    Test::Registry::StripeWebhook::post_succeeded(
        $t, $main_payment_id, $slug, $main_pi_id,
        event_id => $evt1,
    )->status_is(200, 'I4: replay of same event_id returns 200');

    my $enrs2 = $tdb->select('enrollments', '*', { payment_id => $main_payment_id })->hashes;
    is scalar @$enrs2, 1, 'I4: still exactly one enrollment after replay';
};

# ---------------------------------------------------------------------------
# I3: Declined card produces card_declined error and no enrollment.
# ---------------------------------------------------------------------------

subtest 'I3: declined card fails with card_declined and creates no enrollment' => sub {
    my $run3  = make_e2e_run();
    my $step3 = get_payment_step();
    my $result3 = process_payment_step($step3, $run3);

    ok !$result3->{errors}, 'I3: step creates intent without gate error'
        or diag explain $result3->{errors};

    my $pay3    = Registry::DAO::Payment->find($tdb, { id => $result3->{data}{payment_id} });
    my $pi_id3  = $pay3->stripe_payment_intent_id;
    like $pi_id3, qr/^pi_/, 'I3: fresh real PI created for decline test';

    my $decline_err = '';
    eval { Test::Registry::StripeConfirm::confirm($pi_id3, 'pm_card_visa_chargeDeclined') };
    $decline_err = $@;

    like $decline_err, qr/card_declined/,
        'I3: confirm with chargeDeclined card dies with card_declined';

    my $enr3_count = scalar @{ $tdb->select('enrollments', '*', { payment_id => $pay3->id })->hashes };
    is $enr3_count, 0, 'I3: no enrollment created for declined card';

    my $pay3_fresh = Registry::DAO::Payment->find($tdb, { id => $pay3->id });
    isnt $pay3_fresh->status, 'completed',
        'I3: payment status is NOT completed after decline';
};

# ---------------------------------------------------------------------------
# I6: Refund honors plan policy: transfer reversed, application fee returned.
# ---------------------------------------------------------------------------

subtest 'I6: refund reverses transfer and returns application fee per 2% plan policy' => sub {
    my $main_payment = Registry::DAO::Payment->find($tdb, { id => $main_payment_id });
    is $main_payment->status, 'completed',
        'I6 precondition: I1 payment is completed (I4 webhook ran)';

    my $refund = $main_payment->refund($tdb);
    ok $refund->{id}, 'I6: refund object returned from Stripe';

    # The 2% plan has refund_application_fee=true, so the $3.00 platform fee must come back.
    # ponytail: _get is package-private by convention; calling cross-package is intentional
    my $fee = Test::Registry::StripeConfirm::_get("/application_fees/$charge_fee_id");
    is $fee->{amount_refunded}, $EXPECTED_FEE_CENTS,
        "I6: application_fee.amount_refunded == $EXPECTED_FEE_CENTS cents (fee fully returned)";

    # Transfer reversal: verify the connected-account transfer was reversed.
    my $transfer = Test::Registry::StripeConfirm::_get("/transfers/$charge_transfer_id");
    ok $transfer->{amount_reversed} > 0,
        'I6: transfer.amount_reversed > 0 (transfer was reversed)';
};

# ---------------------------------------------------------------------------
# I7: Idempotency -- double submit returns same PI; rotation yields new PI.
# ---------------------------------------------------------------------------

subtest 'I7: double agreeTerms yields same PI id; rotated token yields distinct PI id' => sub {
    my $run7  = make_e2e_run();
    my $step7 = get_payment_step();

    # First submit: creates payment row and real Stripe PI.
    my $result7a = process_payment_step($step7, $run7);
    ok !$result7a->{errors}, 'I7: first process succeeds'
        or diag explain $result7a->{errors};

    my $pay7    = Registry::DAO::Payment->find($tdb, { id => $result7a->{data}{payment_id} });
    my $pi_id_a = $pay7->stripe_payment_intent_id;
    like $pi_id_a, qr/^pi_/, 'I7: first process created a real Stripe PI';

    # Second submit on the SAME run: idempotency_token preserved -> Stripe dedup.
    my $result7b = process_payment_step($step7, $run7);
    ok !$result7b->{errors}, 'I7: second process succeeds'
        or diag explain $result7b->{errors};

    $pay7 = Registry::DAO::Payment->find($tdb, { id => $pay7->id });
    my $pi_id_b = $pay7->stripe_payment_intent_id;
    is $pi_id_b, $pi_id_a,
        'I7: double submit returns the SAME Stripe PI id (idempotency key preserved)';

    # Confirm once: exactly one charge follows.
    my $confirmed7 = Test::Registry::StripeConfirm::confirm($pi_id_a);
    is $confirmed7->{status}, 'succeeded', 'I7: intent confirms as succeeded';

    my $charge7 = Test::Registry::StripeConfirm::charge_for($pi_id_a);
    ok $charge7->{id}, 'I7: charge_for returns a charge for the single confirmed intent';
    is $charge7->{payment_intent}, $pi_id_a,
        'I7: charge.payment_intent matches the single PI (one charge for one confirm)';

    # Rotate the idempotency token -> a genuinely new Stripe PI.
    $pay7->rotate_idempotency_token($tdb);
    my $rotated = $pay7->create_payment_intent($tdb, { description => 'I7 rotate verification' });
    my $pi_id_c = $rotated->{payment_intent_id};
    like $pi_id_c, qr/^pi_/, 'I7: rotated create returns a pi_ id';
    isnt $pi_id_c, $pi_id_a, 'I7: rotated token yields a DISTINCT Stripe PI id';
};

$test_db->cleanup_test_database;
done_testing;
