#!/usr/bin/env perl
# ABOUTME: Tests the application-fee refund call, which the platform makes on its own account
# ABOUTME: Requests are captured and answered by a local app, never sent to Stripe

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Mojo::Parameters;
use Mojolicious::Lite;
use Registry::Service::Stripe;

app->log->level('fatal');
any '/*rest' => sub ($c) { $c->render(json => { id => 'fr_local', object => 'fee_refund' }) };

# Point the client's user agent at the local app and record each request.
# The prepare event fires before the proxy is chosen, so dropping the scheme
# here makes the UA send the request to its own app server.
sub capture ($client) {
    my @seen;
    $client->ua->server->app(app);
    $client->ua->on(prepare => sub ($ua, $tx) {
        push @seen, {
            method  => $tx->req->method,
            url     => $tx->req->url->to_string,
            headers => $tx->req->headers->clone,
            params  => Mojo::Parameters->new($tx->req->body)->to_hash,
        };
        $tx->req->url->scheme(undef);
    });
    return \@seen;
}

my $key = 'sk_test_placeholder_not_a_key';

subtest 'platform client refunds an application fee' => sub {
    my $client = Registry::Service::Stripe->new(api_key => $key);
    my $seen = capture($client);

    my $refund = $client->create_application_fee_refund(
        'fee_123', { amount => 50, _idempotency_key => 'ik_fee' });

    is $refund->{id}, 'fr_local', 'sync wrapper returns the resolved refund';
    is scalar @$seen, 1, 'one request made';
    is $seen->[0]{method}, 'POST', 'a POST';
    is $seen->[0]{url}, 'https://api.stripe.com/v1/application_fees/fee_123/refunds',
        'to the fee refunds endpoint';
    is_deeply $seen->[0]{params}, { amount => 50 }, 'with the amount and nothing else';
    is $seen->[0]{headers}->header('Idempotency-Key'), 'ik_fee', 'carrying the idempotency key';
    is $seen->[0]{headers}->header('Stripe-Account'), undef, 'naming no connected account';
};

subtest 'no idempotency key is sent when none is given' => sub {
    my $client = Registry::Service::Stripe->new(api_key => $key);
    my $seen = capture($client);

    $client->create_application_fee_refund_async('fee_123', { amount => 50 })->wait;

    is $seen->[0]{headers}->header('Idempotency-Key'), undef, 'no Idempotency-Key header';
};

subtest 'fee refund never carries stripe account' => sub {
    my $client = Registry::Service::Stripe->new(api_key => $key)
        ->for_account('acct_tenant_bound');
    my $seen = capture($client);

    $client->retrieve_application_fee_async('fee_123')->wait;
    $client->create_application_fee_refund_async('fee_123', { amount => 50 })->wait;
    $client->create_application_fee_refund('fee_123', { amount => 50 });

    is scalar @$seen, 3, 'three requests made';
    is_deeply [ map { @{ $_->{headers}->every_header('Stripe-Account') } } @$seen ], [],
        'none names the bound account';
};

subtest 'malformed fee id is refused before request' => sub {
    my $client = Registry::Service::Stripe->new(api_key => $key);
    my $seen = capture($client);

    for my $bad (undef, '', 'fee_', 'fee_1/../../charges', '../fee_1', 'fee_1/x',
                 'ch_123', 'fee_a b', "fee_1\n", 'fee_1..') {
        my $shown = defined $bad ? $bad =~ s/\n/\\n/gr : 'undef';
        throws_ok { $client->create_application_fee_refund_async($bad, { amount => 50 }) }
            qr/application fee id/, "refund of '$shown' refused";
        throws_ok { $client->retrieve_application_fee_async($bad) }
            qr/application fee id/, "retrieval of '$shown' refused";
    }
    is scalar @$seen, 0, 'no request made';
};

subtest 'same idempotency key is sent unchanged' => sub {
    my $client = Registry::Service::Stripe->new(api_key => $key);
    my $seen = capture($client);
    my $params = { amount => 50, _idempotency_key => 'fee-refund:42' };

    $client->create_application_fee_refund_async('fee_123', $params)->wait;
    $client->create_application_fee_refund_async('fee_123', $params)->wait;

    is scalar @$seen, 2, 'two requests made';
    is_deeply [ map { $_->{headers}->header('Idempotency-Key') } @$seen ],
        [ 'fee-refund:42', 'fee-refund:42' ], 'both carry the same key unchanged';
    is_deeply $params, { amount => 50, _idempotency_key => 'fee-refund:42' },
        'the caller params are left as given';
};

done_testing;
