# ABOUTME: Gated real-Stripe test suite proving invariants I1-I8 for the money path.
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
use Registry::PriceOps::RevenueShare;
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

# I8 resolves its tenant from a <slug>.localhost Host header, and the base-domain
# list is an environment variable with a default. A shell configured for staging
# work that omits localhost would make tenant resolution fall back to the
# platform schema. Pin it rather than inherit it.
local $ENV{REGISTRY_BASE_DOMAINS} = 'tinyartempire.com,localhost';

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

# Derived, not hardcoded. Nothing on the settle path reads these today --
# calculate_price only branches on dates for early_bird plans, and this fixture
# is 'standard' -- but I8 is the first subtest here to drive the controller,
# which is where a "session has not started" guard would land. A fixture that
# expires turns that into what looks like a Stripe failure. Same reasoning the
# storefront and listing suites already carry.
my @D = localtime( time + 7 * 86_400 );
my $SESSION_START = sprintf '%04d-%02d-%02d', $D[5] + 1900, $D[4] + 1, $D[3];
my @E = localtime( time + 14 * 86_400 );
my $SESSION_END   = sprintf '%04d-%02d-%02d', $E[5] + 1900, $E[4] + 1, $E[3];

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
    time        => "$SESSION_START 10:00:00",
    duration    => 120,
    location_id => $location->id,
    project_id  => $project->id,
    teacher_id  => $teacher->id,
    capacity    => 20,
    metadata    => {},
});

# $150.00 paid session. The fee is asserted against the tenant plan's own rate
# read from the database, never against a literal derived from this number.
my $PLAN_AMOUNT = 150.00;


my $session = Registry::DAO::Session->create($tdb, {
    name       => 'C3 Week',
    start_date => $SESSION_START,
    end_date   => $SESSION_END,
    status     => 'published',
    capacity   => 20,
    metadata   => {},
});
$session->add_events($tdb, $event->id);
Registry::DAO::PricingPlan->create($tdb, {
    session_id => $session->id,
    plan_name  => 'Standard',
    plan_type  => 'standard',
    amount_cents => int( $PLAN_AMOUNT * 100 ),
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
    # Optional child, because every run built here otherwise enrols the SAME
    # child into the SAME session. Once any subtest has seated them, a later
    # cart correctly reads 'foreign', owes the share back and settles
    # refunded/cancelled -- which is #324 working, not a failure, but it makes
    # that subtest a duplicate-seat test rather than whatever it meant to be.
    my $who = shift // $child;
    my $run = $workflow->new_run($tdb);
    $run->update_data($tdb, {
        user_id            => $parent->id,
        children           => [ {
            id         => $who->id,
            first_name => $who->child_name,
            last_name  => '',
            birth_date => '2018-03-15',
            grade      => '3',
        } ],
        session_selections => { $who->id => $session->id },
        enrollment_items   => [ { child_id => $who->id, session_id => $session->id } ],
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

# I8 asserts on the redirect itself, and Mojo::UserAgent's default is
# $ENV{MOJO_MAX_REDIRECTS} || 0 -- so an ambient value would follow the 302 and
# move the assertion's target. Pin it, as t/controller/payment-return-callback.t
# does for the same assertion.
$t->ua->max_redirects(0);
# No dao helper override: Test::Registry::DB::new sets $ENV{DB_URL} to this
# instance, which is what the production helper in Registry.pm reads. Overriding
# it would hand this suite a private copy of tenant resolution, and let a
# regression in the real one pass here.

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

    ok !Registry::DAO::Tenant->find( $db, { slug => $slug } )->stripe_connect_ready,
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

# Link the tenant to the seeded tenant-scope percentage plan, so the fee resolver
# has a plan to read a rate from. The SQL selects by scope and model type, never
# by rate -- the rate itself is whatever that plan carries, and the assertions
# read it from the database rather than assuming it here. Same UPDATE as
# tenant-paid-enrollment.t.
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
my ($main_payment_id, $main_pi_id, $charge_fee_id, $charge_transfer_id,
    $charge_fee_amount);

# ---------------------------------------------------------------------------
# I1+I2: Real Stripe destination charge, correct routing and fee.
# ---------------------------------------------------------------------------

subtest 'I1+I2: destination charge routes to ready account with the fee its plan declares' => sub {
    my $run  = make_e2e_run();
    my $step = get_payment_step();
    my $result = process_payment_step($step, $run);

    ok !$result->{errors}, 'I1/I2: no gate error for ready tenant'
        or diag explain $result->{errors};

    $main_payment_id = $result->{data}{step_data}{payment_id};
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
    # The amount, not just the fee. Rounding a fee to whole cents makes the fee
    # assertion tolerate a band of charge amounts either side of the true one, so
    # a fee that looks right does not establish that the right amount was taken.
    # This is the cart-versus-charge assertion: what Stripe took equals what the
    # parent was shown.
    is $charge->{amount}, $result->{data}{step_data}{total},
        'I2: the amount Stripe charged is the total the cart displayed';

    # Anchored to the fixture price, which the line above cannot be: both the
    # displayed total and the Stripe amount descend from
    # calculate_enrollment_total, so a regression there moves them together and
    # agrees with itself. This is the only amount here anchored outside that
    # function.
    is $charge->{amount}, int( $PLAN_AMOUNT * 100 ),
        'I2: and it is the price the plan actually carries';

    # Read the rate from the database, never from a literal. That is the
    # project's standing rule, and the reason for it is this file: a launch-rate
    # change would otherwise fail here as a stale constant, and the obvious
    # repair is to edit the constant -- which is precisely the drift the rule
    # exists to stop. revenue_share_fraction_for_tenant is the same resolver the
    # charge path uses, so displayed, charged and asserted cannot diverge.
    my $fraction = Registry::PriceOps::RevenueShare::revenue_share_fraction_for_tenant(
        $db, $slug );
    my $expected_fee = int( $charge->{amount} * $fraction + 0.5 );
    is $charge->{application_fee_amount}, $expected_fee,
        "I2: application_fee_amount == $expected_fee cents "
      . "(the tenant plan's own rate, read from the DB)";

    # Runbook section 5 step 3 asks for this on the charge itself. It was
    # asserted only against captured params in t/integration, which cannot show
    # what Stripe actually recorded. on_behalf_of is what makes the tenant the
    # settlement merchant -- bearer of Stripe's fees and of the descriptor the
    # parent sees on their statement.
    is $charge->{on_behalf_of}, $ready_acct,
        'I2: charge.on_behalf_of is the tenant account';

    # Save charge fields for I6 refund assertions
    $charge_fee_id      = $charge->{application_fee};
    $charge_fee_amount  = $charge->{application_fee_amount};
    $charge_transfer_id = $charge->{transfer};
    # charge_for_settled dies unless both are present, so their mere existence
    # is not news. Their shape is: a fee id that is not a fee id means the
    # destination charge was built as something else.
    like $charge_fee_id,      qr/^fee_/, 'I2: the charge carries an application fee';
    like $charge_transfer_id, qr/^tr_/,  'I2: and a transfer to the connected account';
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
    )->status_is(200, 'I4: replay of same event_id returns 200')
     ->content_is('OK (duplicate)',
        'I4: absorbed by the dedup ledger, not merely re-run idempotently');

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

    my $pay3    = Registry::DAO::Payment->find($tdb, { id => $result3->{data}{step_data}{payment_id} });
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
    # 'pending', not merely "not completed". Nothing tells Registry about the
    # decline -- no webhook, no browser return -- so the row must be untouched,
    # and isnt() would also accept a future 'failed' arriving unnoticed.
    is $pay3_fresh->status, 'pending',
        'I3: the declined run leaves its payment row untouched';
};

# ---------------------------------------------------------------------------
# I6: Refund honors plan policy: transfer reversed, application fee returned.
# ---------------------------------------------------------------------------

subtest 'I6: refund reverses transfer and returns the application fee per plan policy' => sub {
    my $main_payment = Registry::DAO::Payment->find($tdb, { id => $main_payment_id });
    is $main_payment->status, 'completed',
        'I6 precondition: I1 payment is completed (I4 webhook ran)';

    # refund_async is the only refund entry point; the synchronous refund() was
    # removed. This file runs outside the daemon's event loop, so settle() can
    # block on the promise here in a way the web path never could.
    my $refund = settle( $main_payment->refund_async($tdb) );
    # The amount, not the object's existence: settle() dies on rejection, so a
    # refund object is always present by the time this line runs.
    is $refund->{amount}, $main_payment->amount_cents,
        'I6: the parent gets the full amount back';

    # The plan carries refund_application_fee=true, so whatever the platform took
    # must come back -- asserted against the fee actually charged, not an amount.
    # ponytail: _get is package-private by convention; calling cross-package is intentional
    my $fee = Test::Registry::StripeConfirm::_get("/application_fees/$charge_fee_id");
    # Against the fee actually charged, not a literal. "The platform returns what
    # it took" is the property under test, and it stays true at any rate -- so
    # this assertion does not need editing when the launch rate moves, and
    # cannot quietly certify the wrong one.
    is $fee->{amount_refunded}, $charge_fee_amount,
        "I6: application_fee.amount_refunded == the $charge_fee_amount cents charged "
      . "(fee fully returned)";

    # Transfer reversal: verify the connected-account transfer was reversed.
    my $transfer = Test::Registry::StripeConfirm::_get("/transfers/$charge_transfer_id");
    # The whole transfer, not merely a positive amount. refund_async always sends
    # reverse_transfer, so `> 0` fails only if that is dropped entirely -- a
    # regression that reversed the wrong amount stays green.
    is $transfer->{amount_reversed}, $transfer->{amount},
        'I6: the whole transfer was reversed, not part of it';
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

    my $pay7    = Registry::DAO::Payment->find($tdb, { id => $result7a->{data}{step_data}{payment_id} });
    my $pi_id_a = $pay7->stripe_payment_intent_id;
    like $pi_id_a, qr/^pi_/, 'I7: first process created a real Stripe PI';

    # Second submit on the SAME run: idempotency_token preserved -> Stripe dedup.
    my $result7b = process_payment_step($step7, $run7);
    ok !$result7b->{errors}, 'I7: second process succeeds'
        or diag explain $result7b->{errors};

    # The row, before the intent. Re-reading $pay7 by its own id only detects a
    # mutation of the first row -- if _reusable_payment_row or the run's
    # payment_id stamp regressed, the second submit would mint a SECOND row with
    # a second confirmable intent, which is exactly what create_payment's comment
    # forbids, and every assertion below would still pass.
    is $result7b->{data}{step_data}{payment_id}, $pay7->id,
        'I7: the second submit reused the same payment row';

    $pay7 = Registry::DAO::Payment->find($tdb, { id => $pay7->id });
    my $pi_id_b = $pay7->stripe_payment_intent_id;
    is $pi_id_b, $pi_id_a,
        'I7: double submit returns the SAME Stripe PI id (idempotency key preserved)';

    # Confirm once: exactly one charge follows.
    my $confirmed7 = Test::Registry::StripeConfirm::confirm($pi_id_a);
    is $confirmed7->{status}, 'succeeded', 'I7: intent confirms as succeeded';

    # A count, not an identity: charge_for follows latest_charge off the intent,
    # so comparing the charge's payment_intent to that intent says nothing. This
    # is a guard on Stripe's side of the contract -- one confirm yields one
    # charge -- and only the test confirms, so no Registry change moves it. The
    # Registry-side half of "no double charge" is the payment-row assertion above.
    my $charges7 = Test::Registry::StripeConfirm::_get(
        "/charges?payment_intent=$pi_id_a" );
    is scalar @{ $charges7->{data} // [] }, 1,
        'I7: one confirm yielded exactly one charge';

    # Rotate the idempotency token -> a genuinely new Stripe PI.
    $pay7->rotate_idempotency_token($tdb);
    my $rotated = $pay7->create_payment_intent($tdb, { description => 'I7 rotate verification' });
    my $pi_id_c = $rotated->{payment_intent_id};
    like $pi_id_c, qr/^pi_/, 'I7: rotated create returns a pi_ id';
    isnt $pi_id_c, $pi_id_a, 'I7: rotated token yields a DISTINCT Stripe PI id';
};


# ---------------------------------------------------------------------------
# I8: The parent's browser return finalizes, against a real confirmed intent.
#
# Runbook section 5 step 2 asks for a paid enrollment "through the
# application". Every other subtest here drives $step->process directly, and
# I4 delivers a webhook -- neither exercises the leg the parent actually
# travels: Stripe redirects the browser back to return_url with
# payment_intent and redirect_status appended, as a GET.
#
# That GET was unreachable until get_workflow_run_step learned to hand the
# intent to the step (B-4). It is otherwise covered only by
# t/controller/payment-return-callback.t, which mocks Stripe. This asserts it
# against a real confirmed intent, and deliberately sends NO webhook, so a
# pass means the browser path alone completed the enrollment.
# ---------------------------------------------------------------------------

subtest "I8: the browser return alone finalizes a real payment" => sub {
    # A child of their own: this asserts a first enrolment completing through
    # the browser, not the duplicate-seat path an already-seated child takes.
    my $i8_child = Registry::DAO::Family->add_child( $tdb, $parent->id, {
        child_name        => 'C3 Browser Child',
        birth_date        => '2018-03-15',
        grade             => '3',
        medical_info      => {},
        emergency_contact => { name => 'Emergency', phone => '555-0199' },
    });

    my $run    = make_e2e_run($i8_child);
    my $step   = get_payment_step();
    my $result = process_payment_step( $step, $run );

    ok !$result->{errors}, 'I8: intent created for the browser leg'
        or diag explain $result->{errors};

    my $payment_id = $result->{data}{step_data}{payment_id};
    my $payment    = Registry::DAO::Payment->find( $tdb, { id => $payment_id } );
    my $pi_id      = $payment->stripe_payment_intent_id;
    like $pi_id, qr/^pi_/, 'I8: a real intent to return from';

    my $confirmed = Test::Registry::StripeConfirm::confirm($pi_id);
    is $confirmed->{status}, 'succeeded', 'I8: intent confirmed as the browser would';

    # The "alone" in this subtest's name, pinned rather than argued. Confirming
    # at Stripe does not touch our database, and _settle_callback treats
    # already_completed exactly like success -- so without this line a future
    # webhook forwarder, or a change that completes the row at intent creation,
    # would turn the assertions below into a no-op that still passes.
    is Registry::DAO::Payment->find( $tdb, { id => $payment_id } )->status,
        'pending',
        'I8: still unsettled before the return -- only the GET can complete it';

    # Exactly what Stripe appends to return_url.
    my $return_url = sprintf '/%s/%s/payment?payment_intent=%s&redirect_status=succeeded',
        $workflow->slug, $run->id, $pi_id;

    # status_is(302) + Location, not isnt(500). The regression this leg exists
    # to prevent is named in get_workflow_run_step's own comment -- "re-rendering
    # the card form would strand them on a paid-but-unconfirmed page". A step
    # result that settled the money but returned stay => 1 would re-render
    # instead of redirecting, and any status it produced would have satisfied
    # isnt(500) while the payment sat completed and the parent stranded.
    # Asserting the redirect itself is what closes that, and it is what the
    # mocked sibling (t/controller/payment-return-callback.t) already does.
    $t->get_ok( $return_url, { Host => "$slug.localhost" } )
      ->status_is(302, 'I8: the return redirects rather than re-rendering')
      ->header_like( Location => qr{/complete$},
          'I8: and sends the parent on to completion, not back to the card form' );

    my $settled = Registry::DAO::Payment->find( $tdb, { id => $payment_id } );
    is $settled->status, 'completed',
        'I8: the browser return alone marked the payment completed';

    my $enrs = $tdb->select( 'enrollments', '*', { payment_id => $payment_id } )->hashes;
    is scalar @$enrs, 1, 'I8: exactly one enrollment, in the tenant schema';
    is $enrs->[0]{status}, 'active', 'I8: and it is active';

    # registry.payments.user_id is NOT NULL REFERENCES registry.users, and this
    # parent exists only in <slug>.users -- so a misrouted INSERT raises rather
    # than depositing a row, and this negative would stay green either way. It is
    # kept as a cheap cross-schema tripwire, not as the evidence that routing
    # worked. The assertion that detects misrouting is the enrollment count
    # above: a row written to the wrong schema leaves that select empty.
    is $db->select( 'registry.payments', ['id'], { user_id => $parent->id } )
           ->hashes->size, 0,
        'I8: and none in registry.payments';
};

$test_db->cleanup_test_database;
done_testing;
