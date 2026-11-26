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
use Test::Registry::SoloVersion qw( accept_solo_at );
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
# Each accepts Solo, as signup does, at a stated 0%: its terms and its run rights.
accept_solo_at( $dao->db, [qw( ta tb )], 0 );

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

subtest 'account from request is ignored' => sub {
    my $run = run_awaiting_card('ta',
        stripe_account      => 'acct_evil_run',
        stripeAccount       => 'acct_evil_run',
        payment_retry_state => {
            payment_id       => 'ignored',
            client_secret    => 'pi_x_secret_y',
            show_stripe_form => 1,
            stripe_account   => 'acct_evil_retry',
        },
    );

    $t->get_ok(payment_url($run) . '?stripe_account=acct_evil_query&stripeAccount=acct_evil_query'
               => { Host => 'ta.localhost' })
      ->status_is(200)
      ->content_like(qr/stripeAccount: 'acct_x'/, 'the intent account is rendered')
      ->content_unlike(qr/acct_evil/, 'no query-string or run-data account is rendered');

    # A form body lands in run data; the page rendered afterwards still names
    # only the intent's account.
    $t->post_ok(payment_url($run) => { Host => 'ta.localhost' }
                => form => { stripe_account => 'acct_evil_body', stripeAccount => 'acct_evil_body' })
      ->content_unlike(qr/acct_evil/, 'the posted account is not rendered');
    $run->update_data($dao->connect_schema('ta')->db, { payment_retry_state => {
        client_secret => 'pi_x_secret_y', show_stripe_form => 1,
    } });
    $t->get_ok(payment_url($run) => { Host => 'ta.localhost' })
      ->status_is(200)
      ->content_like(qr/stripeAccount: 'acct_x'/, 'the intent account is rendered after a post')
      ->content_unlike(qr/acct_evil/, 'the posted account was not kept for a later render');

    # Run data naming another run's payment does not borrow that payment's account.
    my $db    = $dao->connect_schema('ta')->db;
    my $other = Registry::DAO::Payment->find($db, { id => run_awaiting_card('ta')->data->{payment_id} });
    $db->query(q{UPDATE payments SET metadata = jsonb_set(metadata, '{stripe_account_id}', '"acct_evil_other"')
                 WHERE id = ?}, $other->id);
    my $borrower = run_awaiting_card('ta', payment_id => $other->id);
    $t->get_ok(payment_url($borrower) => { Host => 'ta.localhost' })
      ->status_is(200)
      ->content_unlike(qr/acct_evil/, "another run's payment account is not rendered");
};

subtest 'no account renders stripe key alone' => sub {
    # Card form showing, but the run has no payment row behind it.
    my $run = run_awaiting_card('ta');
    $run->update_data($dao->connect_schema('ta')->db, { payment_id => undef });

    $t->get_ok(payment_url($run) => { Host => 'ta.localhost' })
      ->status_is(200)
      ->content_like(qr/Stripe\('pk_test_page'\);/, 'Stripe.js gets the publishable key alone')
      ->content_unlike(qr/stripeAccount/, 'no stripeAccount option at all, empty, null or undefined');
};

subtest 'hostile account value is escaped' => sub {
    my $hostile = q{acct_x'</script><script>alert(1)//};
    # Rendered straight from the template: the step itself only ever supplies
    # an account its Stripe client accepted, which cannot hold a quote.
    my $html = $t->app->build_controller->render_to_string(
        template  => 'summer-camp-registration/payment',
        workflow  => 'summer-camp-registration',
        run       => run_awaiting_card('ta'),
        step_data => {
            show_stripe_form       => 1,
            stripe_publishable_key => 'pk_test_page',
            client_secret          => 'pi_x_secret_y',
            stripe_account         => $hostile,
        },
    );

    unlike $html, qr/\Q$hostile\E/, 'the raw value is not in the page';
    unlike $html, qr/<script>alert/, 'no script element is injected';
    like $html, qr/stripeAccount: 'acct_x&#39;&lt;\/script&gt;&lt;script&gt;alert\(1\)\/\/'/,
        'the value is rendered escaped inside its JS string';
};

subtest 'tenant a page never renders tenant b account' => sub {
    my $run_a = run_awaiting_card('ta');
    my $run_b = run_awaiting_card('tb');

    $t->get_ok(payment_url($run_a) => { Host => 'ta.localhost' })
      ->status_is(200)
      ->content_like(qr/stripeAccount: 'acct_x'/, "tenant a's page names its own account")
      ->content_unlike(qr/acct_tb/, "and never tenant b's");

    $t->get_ok(payment_url($run_b) => { Host => 'tb.localhost' })
      ->status_is(200)
      ->content_like(qr/stripeAccount: 'acct_tb'/, "tenant b's page names its own account")
      ->content_unlike(qr/acct_x/, "and never tenant a's");
};

subtest 'rendered account is the intent account after row change' => sub {
    my $run = run_awaiting_card('ta');
    $dao->db->query(q{UPDATE registry.tenants SET stripe_connect_account_id = 'acct_moved'
                      WHERE slug = 'ta'});

    $t->get_ok(payment_url($run) => { Host => 'ta.localhost' })
      ->status_is(200)
      ->content_like(qr/stripeAccount: 'acct_x'/, 'the account the intent was created on')
      ->content_unlike(qr/acct_moved/, "not the tenant row's new account");

    $dao->db->query(q{UPDATE registry.tenants SET stripe_connect_account_id = 'acct_x'
                      WHERE slug = 'ta'});
};

subtest 'page never contains a secret key' => sub {
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_never_on_the_page';
    my $run = run_awaiting_card('ta');

    $t->get_ok(payment_url($run) => { Host => 'ta.localhost' })
      ->status_is(200)
      ->content_like(qr/stripeAccount: 'acct_x'/, 'the card form is rendered')
      ->content_unlike(qr/sk_(?:test|live)_/, 'no Stripe secret key is in the page');
};

# A declined card leaves the row failed, and the retry intent is created on
# the same row and account. The card form for that retry must still carry the
# account, or the browser cannot confirm the retry.
subtest 'a declined card retry form keeps the intent account' => sub {
    my $run = run_awaiting_card('ta');
    $dao->connect_schema('ta')->db->query(
        q{UPDATE payments SET status = 'failed' WHERE id = ?}, $run->data->{payment_id} );
    $t->get_ok( payment_url($run) => { Host => 'ta.localhost' } )->status_is(200)
      ->content_like( qr/stripeAccount: 'acct_x'/, 'the retry form is initialised on the intent account' );
};

done_testing();
