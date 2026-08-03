#!/usr/bin/env perl
# ABOUTME: Stripe returns the browser from confirmPayment with a GET, so the GET
# ABOUTME: handler must finish the enrollment instead of re-rendering the form.
use 5.42.0;
use warnings;
use utf8;
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }
use lib qw(lib t/lib);
use Test::More;
use Test::MockObject;
use Test::Registry::Mojo;
use Registry;
use Test::Registry::DB;
use Registry::DAO qw(Workflow);
use Registry::DAO::Payment;
use Registry::DAO::WorkflowRun;
use Registry::DAO::WorkflowStep;
use Mojo::Home;
use Mojo::Promise;
use YAML::XS qw(Load);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($dao, $file->slurp);
}

my $t = Test::Registry::Mojo->new('Registry');
# Do not follow redirects: the redirect itself is the evidence that the run
# advanced past payment rather than re-rendering the card form.
$t->ua->max_redirects(0);

my $workflow     = $dao->find(Workflow => { slug => 'summer-camp-registration' });
my $payment_step = Registry::DAO::WorkflowStep->find($dao->db, {
    workflow_id => $workflow->id, slug => 'payment',
});

# A run parked on the payment step, as it is when the parent is sent to Stripe.
sub run_awaiting_payment () {
    my $run = $workflow->new_run($dao->db);
    $dao->db->update('workflow_runs',
        { latest_step_id => $payment_step->id },
        { id => $run->id },
    );
    $run->update_data($dao->db, {
        user_id    => 'some-user-id',
        payment_id => '00000000-0000-0000-0000-000000000001',
    });
    return $run;
}

# Stripe's own redirect params. confirmPayment appends these to return_url; the
# browser arrives as a plain GET, carrying no form body at all.
my %stripe_return = (
    payment_intent               => 'pi_returned_from_stripe',
    payment_intent_client_secret => 'pi_returned_from_stripe_secret_xyz',
    redirect_status              => 'succeeded',
);

sub succeeded_payment () {
    my $mock = Test::MockObject->new;
    $mock->set_always('id', '00000000-0000-0000-0000-000000000001');
    $mock->set_always('process_payment_async',
        Mojo::Promise->resolve({ success => 1 }));
    # The finalizer the payment_intent.succeeded webhook also runs; idempotent.
    $mock->set_true('finalize_enrollment');
    return $mock;
}

subtest 'Stripe return GET completes the run instead of re-rendering payment' => sub {
    my $run  = run_awaiting_payment();
    my $mock = succeeded_payment();

    no warnings qw(redefine once);
    local *Registry::DAO::Payment::find = sub { $mock };

    my $url = "/summer-camp-registration/@{[ $run->id ]}/payment"
            . '?' . join '&', map {"$_=$stripe_return{$_}"} sort keys %stripe_return;

    $t->get_ok($url)
      ->status_is(302)
      ->header_like(Location => qr{/complete$},
                    'redirects on to the completion step');

    ok $mock->called('process_payment_async'),
        'the returned intent was handed to the payment step';
    ok $mock->called('finalize_enrollment'),
        'enrollment was finalized on the parent return leg';
};

subtest 'an ordinary GET with no Stripe params still renders the form' => sub {
    my $run = run_awaiting_payment();

    $t->get_ok("/summer-camp-registration/@{[ $run->id ]}/payment")
      ->status_is(200);
};

subtest 'the Stripe params alone do not advance a non-payment step' => sub {
    # The dispatch is keyed on the step handling payment callbacks, not on the
    # query string. Otherwise any step URL could be advanced by appending
    # ?payment_intent=... to a GET.
    my $run = $workflow->new_run($dao->db);
    my ($landing) = Registry::DAO::WorkflowStep->find($dao->db, {
        workflow_id => $workflow->id, slug => 'landing',
    });
    $dao->db->update('workflow_runs',
        { latest_step_id => $landing->id },
        { id => $run->id },
    );

    $t->get_ok("/summer-camp-registration/@{[ $run->id ]}/landing"
             . '?payment_intent=pi_forged&redirect_status=succeeded')
      ->status_is(200);
};

done_testing();
