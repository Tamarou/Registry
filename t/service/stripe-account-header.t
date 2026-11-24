#!/usr/bin/env perl
# ABOUTME: Tests that the Stripe client names a connected account in a Stripe-Account header
# ABOUTME: Requests are captured and answered by a local app, never sent to Stripe

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Mojo::Promise;
use Mojolicious::Lite;
use Registry::Service::Stripe;

app->log->level('fatal');
any '/*rest' => sub ($c) { $c->render(json => { id => 'obj_local' }) };

# Point the client's user agent at the local app and record each request's
# headers. The prepare event fires before the proxy is chosen, so dropping
# the scheme here makes the UA send the request to its own app server.
sub capture ($client) {
    my @seen;
    $client->ua->server->app(app);
    $client->ua->on(prepare => sub ($ua, $tx) {
        push @seen, $tx->req->headers->clone;
        $tx->req->url->scheme(undef);
    });
    return \@seen;
}

sub accounts_sent ($headers) {
    return [ map { @{ $_->every_header('Stripe-Account') } } @$headers ];
}

my $key = 'sk_test_placeholder_not_a_key';

subtest 'bound client sends stripe account on POST and GET' => sub {
    my $client = Registry::Service::Stripe->new(api_key => $key)
        ->for_account('acct_header_test');
    my $seen = capture($client);

    $client->create_payment_intent_async({ amount => 1000, currency => 'usd' })->wait;
    $client->retrieve_payment_intent_async('pi_local')->wait;

    is scalar @$seen, 2, 'two requests made';
    is_deeply accounts_sent([ $seen->[0] ]), ['acct_header_test'], 'POST carries the account';
    is_deeply accounts_sent([ $seen->[1] ]), ['acct_header_test'], 'GET carries the account';
};

subtest 'from_env client sends no stripe account header' => sub {
    local $ENV{STRIPE_SECRET_KEY} = $key;
    my $client = Registry::Service::Stripe->from_env;
    my $seen = capture($client);

    $client->create_payment_intent_async({ amount => 1000, currency => 'usd' })->wait;
    $client->retrieve_payment_intent_async('pi_local')->wait;

    is scalar @$seen, 2, 'two requests made';
    is_deeply accounts_sent($seen), [], 'no Stripe-Account header on either request';
};

subtest 'bound client passes idempotency keys through' => sub {
    my $client = Registry::Service::Stripe->new(api_key => $key)
        ->for_account('acct_header_test');
    my $seen = capture($client);

    $client->create_payment_intent_async({ amount => 1000, currency => 'usd', _idempotency_key => 'ik_pi' })->wait;
    $client->create_refund_async({ payment_intent => 'pi_local', _idempotency_key => 'ik_re' })->wait;

    is $seen->[0]->header('Idempotency-Key'), 'ik_pi', 'payment intent keeps its idempotency key';
    is $seen->[1]->header('Idempotency-Key'), 'ik_re', 'refund keeps its idempotency key';
    is_deeply accounts_sent($seen), ['acct_header_test', 'acct_header_test'], 'both name the account';
};

subtest 'for_account refuses undef or empty account' => sub {
    my $client = Registry::Service::Stripe->new(api_key => $key);
    my $seen = capture($client);

    throws_ok { $client->for_account(undef) } qr/Stripe account/, 'undef refused';
    throws_ok { $client->for_account('') }    qr/Stripe account/, 'empty string refused';
    is scalar @$seen, 0, 'no request made';
};

subtest 'for_account refuses malformed or header injecting account' => sub {
    my $client = Registry::Service::Stripe->new(api_key => $key);
    my $seen = capture($client);

    for my $bad ('acct_', 'cus_123', 'acct_ab cd', 'acct_x-y', "acct_x\r\nX-Evil: 1", "acct_x\n") {
        (my $shown = $bad) =~ s/\r/\\r/g; $shown =~ s/\n/\\n/g;
        throws_ok { $client->for_account($bad) } qr/Stripe account/, "'$shown' refused";
    }
    is scalar @$seen, 0, 'no request made';
};

subtest 'binding leaves the source client unbound' => sub {
    local $ENV{STRIPE_SECRET_KEY} = $key;
    my $client = Registry::Service::Stripe->from_env;
    my $seen = capture($client);

    $client->for_account('acct_header_test');
    $client->retrieve_payment_intent_async('pi_local')->wait;

    is $client->stripe_account, undef, 'source client still unbound';
    is_deeply accounts_sent($seen), [], 'its next request carries no Stripe-Account';
};

subtest 'rebinding sends exactly one stripe account header' => sub {
    my $client = Registry::Service::Stripe->new(api_key => $key)
        ->for_account('acct_a')->for_account('acct_b');
    my $seen = capture($client);

    $client->retrieve_payment_intent_async('pi_local')->wait;

    is_deeply accounts_sent($seen), ['acct_b'], 'only the new account is sent';
};

subtest 'interleaved clients send only their own account' => sub {
    my $platform = Registry::Service::Stripe->new(api_key => $key);
    my $a = $platform->for_account('acct_tenanta');
    my $b = $platform->for_account('acct_tenantb');
    my ($seen_a, $seen_b) = (capture($a), capture($b));

    Mojo::Promise->all(
        $a->retrieve_payment_intent_async('pi_a1'),
        $b->retrieve_payment_intent_async('pi_b1'),
        $a->create_payment_intent_async({ amount => 100, currency => 'usd' }),
        $b->create_payment_intent_async({ amount => 200, currency => 'usd' }),
    )->wait;

    is_deeply accounts_sent($seen_a), ['acct_tenanta', 'acct_tenanta'], 'tenant A sends only its account';
    is_deeply accounts_sent($seen_b), ['acct_tenantb', 'acct_tenantb'], 'tenant B sends only its account';
};

done_testing;
