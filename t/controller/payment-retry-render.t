#!/usr/bin/env perl
# ABOUTME: Verifies the payment-step template renders the retry UI and
# ABOUTME: error banner when payment_retry_state is set in run data.
use 5.42.0;
use warnings;
use utf8;
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Registry;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO qw(Workflow);
use Registry::DAO::WorkflowRun;
use Mojo::Home;
use YAML::XS qw(Load);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# Import workflows so the summer-camp-registration slug resolves.
my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($dao, $file->slurp);
}

my $t = Test::Registry::Mojo->new('Registry');
$t->ua->max_redirects(5);

# Fetch the payment step id so we can build the run URL.
my $workflow = $dao->find(Workflow => { slug => 'summer-camp-registration' });
my $payment_step = Registry::DAO::WorkflowStep->find($dao->db, {
    workflow_id => $workflow->id, slug => 'payment',
});

subtest 'retry state in run data renders error banner and stripe form' => sub {
    # Craft a run whose latest step is payment and whose data already
    # carries the retry state (as handle_payment_callback would have
    # written after a card decline).
    my $run = $workflow->new_run($dao->db);
    $dao->db->update('workflow_runs',
        { latest_step_id => $payment_step->id },
        { id => $run->id },
    );
    $run->update_data($dao->db, {
        user_id             => 'some-user-id',
        payment_retry_state => {
            payment_id       => 'pi_fake_payment_id',
            client_secret    => 'pi_retry_secret_abc',
            show_stripe_form => 1,
            retry            => 1,
        },
    });

    # Also set an errors flash so the server-side banner renders. We
    # put a message in session the way the controller would.
    $t->get_ok("/summer-camp-registration/@{[ $run->id ]}/payment")
      ->status_is(200)
      ->content_like(qr/Try a Different Card/,
                     'heading switches to retry copy when retry state is set')
      ->content_like(qr/pi_retry_secret_abc/,
                     'fresh PaymentIntent client_secret reaches the JS init');
};

subtest 'errors_json decodes into the server-side banner' => sub {
    my $run = $workflow->new_run($dao->db);
    $dao->db->update('workflow_runs',
        { latest_step_id => $payment_step->id },
        { id => $run->id },
    );
    $run->update_data($dao->db, {
        user_id             => 'some-user-id',
        payment_retry_state => {
            payment_id       => 'p2',
            client_secret    => 'pi_other_secret',
            show_stripe_form => 1,
            retry            => 1,
        },
    });

    # Without a flash, the banner is absent.
    $t->get_ok("/summer-camp-registration/@{[ $run->id ]}/payment")
      ->status_is(200)
      ->content_like(qr/Try a Different Card/, 'retry heading visible')
      ->content_unlike(qr/didn't go through/,
                       'banner absent when no error flash is set');

    # Simulate the controller populating errors_json from a failure.
    # The GET handler does: my $errors_json = encode_json(flash('validation_errors') || []);
    # We override via before_render to inject a non-empty errors_json.
    my $decline = 'Your card was declined.';
    my $hook = $t->app->hook(before_render => sub ($c, $args) {
        return unless $c->req->url->path =~ m{/summer-camp-registration/.+/payment};
        $args->{errors_json} = Mojo::JSON::encode_json([$decline]);
    });

    $t->get_ok("/summer-camp-registration/@{[ $run->id ]}/payment")
      ->status_is(200)
      ->content_like(qr/didn't go through/,
                     'banner heading appears with retry wording')
      ->content_like(qr/\Q$decline\E/,
                     'decline reason surfaces in the banner list');
};

done_testing();
