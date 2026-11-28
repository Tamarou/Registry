#!/usr/bin/env perl
# ABOUTME: The session cart's payment page initialises Stripe.js with the account the
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
use Test::Registry::Helpers qw( authenticate_as import_all_workflows days_from_now );
use Test::Registry::Sessions qw( make_session session_offer held_cart );
use Registry::DAO::FamilyMember;
use Registry::DAO::Payment;
use Registry::DAO::WorkflowRun;
use Registry::Service::Stripe;
use Mojo::Promise;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;
$ENV{STRIPE_PUBLISHABLE_KEY} = 'pk_test_page';
local $ENV{STRIPE_SECRET_KEY} = 'sk_test_never_on_the_page';

# Each tenant gets its own schema, with the workflows imported into it, and its
# own ready Stripe account on its tenants row.
for my $tenant ([ ta => 'acct_x' ], [ tb => 'acct_tb' ]) {
    my ($slug, $acct) = @$tenant;
    Test::Registry::Fixtures::create_tenant($dao->db, { name => "Tenant $slug", slug => $slug });
    $dao->db->query(q{UPDATE registry.tenants SET stripe_connect_account_id = ?, stripe_charges_enabled = TRUE,
                      stripe_details_submitted = TRUE WHERE slug = ?}, $acct, $slug);
    import_all_workflows( $dao->connect_schema($slug) );
}
# Each accepts Solo, as signup does, at a stated 0%: its terms and its run rights.
accept_solo_at( $dao->db, [qw( ta tb )], 0 );

no warnings 'redefine';
my $intents = 0;
local *Registry::Service::Stripe::create_payment_intent_async = sub ( $self, $p ) {
    $intents++;
    Mojo::Promise->resolve( { id => "pi_x$intents", client_secret => 'pi_x_secret_y' } );
};
local *Registry::Service::Stripe::retrieve_payment_intent_async = sub ( $self, $id ) {
    Mojo::Promise->resolve( { id => $id, status => 'requires_payment_method',
        last_payment_error => { message => 'Your card was declined.' } } );
};

# A held cart in $slug, and a client signed in as its parent: the run answers
# only to its parent, so each is visited by its own.
my %owner;
sub held_in ($slug) {
    my $tdao = $dao->connect_schema($slug);
    my $db   = $tdao->db;
    state $n = 0; $n++;
    my $user = Test::Registry::Fixtures::create_user( $tdao, { name => "Parent $n", username => "parent$n",
        email => "parent$n\@example.com", user_type => 'parent' } );
    my $kid = Registry::DAO::FamilyMember->create( $db, { family_id => $user->id, child_name => "Kid $n", birth_date => '2016-01-01' } );
    my $s   = make_session( $db, days => [ map { days_from_now($_) } 30 .. 32 ] );
    my ($run) = held_cart( $tdao, $user->id, [ $kid->id, $s->id, session_offer( $db, $s, price_cents => 5000 )->id, 'pay' ] );
    my $client = Test::Registry::Mojo->new('Registry');
    $client->ua->max_redirects(5);
    authenticate_as( $client, $user );
    $owner{ $run->id } = $client;
    return $run;
}
sub as_owner ($run) { $owner{ $run->id } }
sub payment_url ($run) { "/session-checkout/@{[ $run->id ]}/payment" }
sub pay ( $run, $slug, @form ) { as_owner($run)->post_ok( payment_url($run) => { Host => "$slug.localhost" } => @form ) }

subtest 'payment page initialises stripe with the intent account' => sub {
    my $run = held_in('ta');
    pay( $run, 'ta' )->status_is(200)
      ->content_like(qr/Stripe\("pk_test_page",\s*\{ stripeAccount: "acct_x" \}\)/,
                     'Stripe.js is initialised on the account the intent was created on');
};

subtest 'account from request is ignored' => sub {
    my $run = held_in('ta');
    as_owner($run)->post_ok( payment_url($run) . '?stripe_account=acct_evil_query&stripeAccount=acct_evil_query'
        => { Host => 'ta.localhost' }
        => form => { stripe_account => 'acct_evil_body', stripeAccount => 'acct_evil_body' } )
      ->status_is(200)
      ->content_like(qr/stripeAccount: "acct_x"/, 'the intent account is rendered')
      ->content_unlike(qr/acct_evil/, 'no query-string or posted account is rendered');
};

subtest 'hostile account value is escaped' => sub {
    my $hostile = q{acct_x'</script><script>alert(1)//};
    # Rendered straight from the template: the step itself only ever supplies
    # the account its payment snapshotted, which cannot hold a quote.
    my $run  = held_in('ta');
    my $html = as_owner($run)->app->build_controller->render_to_string(
        template  => 'session-checkout/payment',
        workflow  => 'session-checkout',
        run       => $run,
        action    => '/',
        step_data => { show_stripe_form => 1, client_secret => 'pi_x_secret_y', stripe_account => $hostile },
    );

    unlike $html, qr/\Q$hostile\E/, 'the raw value is not in the page';
    unlike $html, qr{</script><script>alert}, 'no script element is injected';
    like $html, qr{stripeAccount: "acct_x'<\\/script><script>alert\(1\)\\/\\/"},
        'the value is rendered escaped inside its JS string';
};

subtest 'tenant a page never renders tenant b account' => sub {
    my $run_a = held_in('ta');
    my $run_b = held_in('tb');

    pay( $run_a, 'ta' )->status_is(200)
      ->content_like(qr/stripeAccount: "acct_x"/, "tenant a's page names its own account")
      ->content_unlike(qr/acct_tb/, "and never tenant b's");

    pay( $run_b, 'tb' )->status_is(200)
      ->content_like(qr/stripeAccount: "acct_tb"/, "tenant b's page names its own account")
      ->content_unlike(qr/acct_x/, "and never tenant a's");
};

subtest 'rendered account is the intent account after row change' => sub {
    my $run = held_in('ta');
    pay( $run, 'ta' )->status_is(200);
    $dao->db->query(q{UPDATE registry.tenants SET stripe_connect_account_id = 'acct_moved' WHERE slug = 'ta'});

    pay( $run, 'ta' )->status_is(200)
      ->content_like(qr/stripeAccount: "acct_x"/, 'the account the intent was created on')
      ->content_unlike(qr/acct_moved/, "not the tenant row's new account");

    $dao->db->query(q{UPDATE registry.tenants SET stripe_connect_account_id = 'acct_x' WHERE slug = 'ta'});
};

subtest 'page never contains a secret key' => sub {
    my $run = held_in('ta');
    pay( $run, 'ta' )->status_is(200)
      ->content_like(qr/stripeAccount: "acct_x"/, 'the card form is rendered')
      ->content_unlike(qr/sk_(?:test|live)_/, 'no Stripe secret key is in the page');
};

# A declined card leaves the payment failed, and paying again starts a new
# charge on the seller's account. Its card form must carry that account, or
# the browser cannot confirm it.
subtest 'a declined card retry form keeps the intent account' => sub {
    my $run = held_in('ta');
    pay( $run, 'ta' )->status_is(200);
    # Followed by hand: a redirect would drop the tenant's Host.
    as_owner($run)->ua->max_redirects(0);
    as_owner($run)->get_ok( payment_url($run) . "?payment_intent=pi_x$intents" => { Host => 'ta.localhost' } )
      ->status_is(302);
    as_owner($run)->ua->max_redirects(5);
    as_owner($run)->get_ok( payment_url($run) => { Host => 'ta.localhost' } )
      ->content_like( qr/Your card was declined/, 'declined' );
    pay( $run, 'ta' )->status_is(200)
      ->content_like( qr/stripeAccount: "acct_x"/, 'the retry form is initialised on the intent account' );
};

done_testing();
