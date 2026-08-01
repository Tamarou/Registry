#!/usr/bin/env perl
# ABOUTME: When Stripe reports a payment failure, the workflow step
# ABOUTME: should re-render the payment form with a fresh intent so the
# ABOUTME: parent can retry -- instead of dumping them at the terms page.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::MockObject;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::Payment;
use Registry::DAO::WorkflowSteps::Payment;
use Test::Registry::Async qw( settle );
use Mojo::Promise;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Retry Test Tenant',
    slug => 'retry_test',
});
$dao->db->query('SELECT clone_schema(?)', 'retry_test');
$dao = Registry::DAO->new(url => $test_db->uri, schema => 'retry_test');
my $db = $dao->db;

my $user = Registry::DAO::User->create($db, {
    name      => 'Parent',
    username  => 'parent_retry',
    email     => 'parent@retry.local',
    user_type => 'parent',
    password  => 'x',
});

# Fake payment id -- we mock Payment->find so no row is required.
my $payment_id = '00000000-0000-0000-0000-000000000001';

# Minimal workflow + run so the step can call $run->data etc.
my $workflow = Registry::DAO::Workflow->create($db, {
    name        => 'Retry Test Flow',
    slug        => 'retry_test_flow',
    description => 'minimal',
    first_step  => 'payment',
});
$workflow->add_step($db, {
    slug        => 'payment',
    description => 'Payment',
    class       => 'Registry::DAO::WorkflowSteps::Payment',
});
my $run = $workflow->new_run($db);
$run->update_data($db, {
    user_id    => $user->id,
    payment_id => $payment_id,
});

my $step = Registry::DAO::WorkflowStep->find($db, {
    workflow_id => $workflow->id, slug => 'payment',
});

# Swap in a Payment whose Stripe methods are mocked. The workflow step
# loads Payment by id, so we monkey-patch the class methods to inject
# our mock.
#
# A failing $process_result must carry the intent_status process_payment_async
# really returns. Only a terminal state (requires_payment_method =
# declined, or canceled) earns a fresh intent; requires_action means the
# customer is mid-3DS and minting a replacement would open a
# double-charge window. A bare {success=>0} is a transport error and
# deliberately gets no retry.
#
# The step drives Stripe through the *_async methods, so the mocks hand back
# promises: a blocking call in the web path can never settle inside the
# daemon's running event loop.
sub mock_payment_with_outcome ($process_result, %more) {
    my $mock = Test::MockObject->new;
    $mock->set_always('id',                    $payment_id);
    $mock->set_always('process_payment_async', Mojo::Promise->resolve($process_result));
    # Before minting a replacement intent the retry path cancels the
    # superseded one and rotates the idempotency token. undef here means
    # there is no prior intent to cancel, so no stripe_client is needed.
    $mock->set_always('stripe_payment_intent_id', undef);
    $mock->set_always('rotate_idempotency_token', 1);
    if (exists $more{retry_intent}) {
        $mock->set_always('create_payment_intent_async',
            Mojo::Promise->resolve($more{retry_intent}));
    }
    elsif (exists $more{retry_dies}) {
        $mock->set_always('create_payment_intent_async',
            Mojo::Promise->reject($more{retry_dies}));
    }
    return $mock;
}

subtest 'recoverable failure re-renders form with a fresh client_secret' => sub {
    my $mock = mock_payment_with_outcome(
        {   success       => 0,
            error         => 'Your card was declined.',
            intent_status => 'requires_payment_method',
        },
        retry_intent => {
            client_secret     => 'pi_new_secret_123',
            payment_intent_id => 'pi_new_123',
        },
    );

    # handle_payment_callback looks up the Payment via Payment->find.
    # Intercept it for the duration of the test.
    no warnings 'redefine';
    local *Registry::DAO::Payment::find = sub { $mock };

    my $result = settle($step->handle_payment_callback($db, $run, {
        payment_intent_id => 'pi_old_failed',
    }));

    ok($result->{errors}, 'error array included');
    like($result->{errors}[0], qr/declined/i, 'message surfaces the decline reason');
    ok($result->{data}{show_stripe_form},
       'form stays visible so retry is possible');
    is($result->{data}{client_secret}, 'pi_new_secret_123',
       'fresh PaymentIntent client_secret delivered');
    is($result->{data}{payment_id}, $payment_id,
       'payment record is reused, not orphaned');
    ok($result->{data}{retry}, 'retry flag set for template UX');
};

subtest 'if a new intent cannot be issued, still surface an error' => sub {
    # A genuine decline, so the step does reach for a fresh intent -- and
    # Stripe is down when it tries.
    my $mock = mock_payment_with_outcome(
        {   success       => 0,
            error         => 'Your card was declined.',
            intent_status => 'requires_payment_method',
        },
        retry_dies => 'Stripe unreachable',
    );

    no warnings 'redefine';
    local *Registry::DAO::Payment::find = sub { $mock };

    my $result = settle($step->handle_payment_callback($db, $run, {
        payment_intent_id => 'pi_old_failed',
    }));

    ok($result->{errors}, 'error array included');
    ok(!$result->{data}{show_stripe_form},
       'form hidden when retry is genuinely impossible');
};

subtest 'retry state persists in run data for next GET' => sub {
    my $mock = mock_payment_with_outcome(
        {   success       => 0,
            error         => 'Your card was declined.',
            intent_status => 'requires_payment_method',
        },
        retry_intent => {
            client_secret     => 'pi_retry_secret',
            payment_intent_id => 'pi_retry',
        },
    );

    no warnings 'redefine';
    local *Registry::DAO::Payment::find = sub { $mock };

    settle($step->handle_payment_callback($db, $run, {
        payment_intent_id => 'pi_old_failed',
    }));

    # Reload the run to make sure data was persisted.
    my $reloaded = Registry::DAO::WorkflowRun->find($db, { id => $run->id });
    my $retry_state = $reloaded->data->{payment_retry_state};
    ok($retry_state, 'payment_retry_state stored in run data');
    is($retry_state->{client_secret}, 'pi_retry_secret',
       'client_secret persisted for the retry GET');
    ok($retry_state->{show_stripe_form}, 'show_stripe_form persisted');
    ok($retry_state->{retry},             'retry flag persisted');

    # prepare_template_data surfaces the retry state into step_data.
    my $tpl_data = $step->prepare_template_data($db, $reloaded);
    is($tpl_data->{step_data}{client_secret}, 'pi_retry_secret',
       'template data carries the retry client_secret');
    ok($tpl_data->{step_data}{show_stripe_form},
       'template data flags the stripe form for re-display');
};

subtest 'successful payment still transitions to complete' => sub {
    my $mock = Test::MockObject->new;
    $mock->set_always('id', $payment_id);
    $mock->set_always('process_payment_async',
        Mojo::Promise->resolve({ success => 1, payment => $mock }));
    # A successful callback finalizes the enrollment; stub it so the mock
    # doesn't warn about the un-mocked call.
    $mock->set_always('finalize_enrollment', 1);

    no warnings 'redefine';
    local *Registry::DAO::Payment::find = sub { $mock };

    my $result = settle($step->handle_payment_callback($db, $run, {
        payment_intent_id => 'pi_ok',
    }));

    is($result->{next_step}, 'complete',
       'success still advances to complete step');
};

done_testing();
