#!/usr/bin/env perl
# ABOUTME: Tests that the Stripe client names a connected account in a Stripe-Account header
# ABOUTME: Requests are captured and answered by a local app, never sent to Stripe

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
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

done_testing;
