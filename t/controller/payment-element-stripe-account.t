#!/usr/bin/env perl
# ABOUTME: The registration payment page initialises Stripe.js with the account the
# ABOUTME: payment intent was created on, since a direct charge confirms only there.
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
use Registry::DAO::Payment;
use Registry::DAO::User;
use Registry::DAO::WorkflowRun;
use Registry::DAO::WorkflowStep;
use Mojo::Home;
use YAML::XS qw(Load);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;
$ENV{STRIPE_PUBLISHABLE_KEY} = 'pk_test_page';

my @files = grep { !Load($_->slurp)->{draft} }
    Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;

# Each tenant gets its own schema, with the registration workflow imported into
# it, and its own Stripe account on its tenants row.
for my $tenant ([ ta => 'acct_x' ], [ tb => 'acct_tb' ]) {
    my ($slug, $acct) = @$tenant;
    Test::Registry::Fixtures::create_tenant($dao->db, { name => "Tenant $slug", slug => $slug });
    $dao->db->query('UPDATE registry.tenants SET stripe_connect_account_id = ? WHERE slug = ?',
        $acct, $slug);
    $dao->db->query('SELECT clone_schema(?)', $slug);
    my $tenant_dao = $dao->connect_schema($slug);
    Workflow->from_yaml($tenant_dao, $_->slurp) for @files;
}

my $t = Test::Registry::Mojo->new('Registry');
$t->ua->max_redirects(5);

# A run on the payment step of $slug whose payment intent is awaiting the card
# form, as create_payment leaves it. The payment row snapshots the tenant's
# account at creation, which is where the intent was created.
sub run_awaiting_card ($slug, %extra_data) {
    my $db       = $dao->connect_schema($slug)->db;
    my $workflow = Registry::DAO::Workflow->find($db, { slug => 'summer-camp-registration' });
    my $step     = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id, slug => 'payment',
    });
    state $n = 0; $n++;
    my $user = Registry::DAO::User->create($db, {
        name => "Parent $n", username => "parent$n", email => "parent$n\@example.com",
        user_type => 'parent',
    });
    my $run = $workflow->new_run($db);
    $db->update('workflow_runs', { latest_step_id => $step->id }, { id => $run->id });
    my $payment = Registry::DAO::Payment->create($db, {
        user_id      => $user->id,
        amount_cents => 5000,
        metadata     => { tenant_slug => $slug, workflow_run_id => $run->id },
    });
    $run->update_data($db, {
        __tenant_slug       => $slug,
        user_id             => $user->id,
        payment_id          => $payment->id,
        payment_retry_state => {
            payment_id       => $payment->id,
            client_secret    => 'pi_x_secret_y',
            show_stripe_form => 1,
        },
        %extra_data,
    });
    return $run;
}

sub payment_url ($run) { "/summer-camp-registration/@{[ $run->id ]}/payment" }

subtest 'payment page initialises stripe with the intent account' => sub {
    my $run = run_awaiting_card('ta');
    $t->get_ok(payment_url($run) => { Host => 'ta.localhost' })
      ->status_is(200)
      ->content_like(qr/Stripe\('pk_test_page', \{ stripeAccount: 'acct_x' \}\)/,
                     'Stripe.js is initialised on the account the intent was created on');
};

done_testing();
