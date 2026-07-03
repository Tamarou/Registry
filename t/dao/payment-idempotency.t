#!/usr/bin/env perl
# ABOUTME: Tests that create_payment_intent_async threads _idempotency_key as HTTP header
# ABOUTME: and strips it from the form payload, without mutating the caller's hashref.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Registry::Service::Stripe;
use Mojo::Promise;
use Mojo::Transaction::HTTP;

my $svc = Registry::Service::Stripe->new(api_key => 'sk_test_fake_b1');

# Build a fake HTTP transaction that satisfies _request_async's ->then handler:
# result->is_success must be true and result->body must return valid JSON.
sub _fake_tx {
    my $tx = Mojo::Transaction::HTTP->new;
    $tx->res->code(200);
    $tx->res->body('{"id":"pi_b1_fake"}');
    return $tx;
}

# Verify fake tx shape satisfies the production handler before relying on it.
{
    my $ft = _fake_tx();
    ok $ft->result->is_success, 'fake tx shape: result->is_success is true';
    like $ft->result->body, qr/pi_b1_fake/, 'fake tx shape: result->body has expected JSON';
}

my $captured;
{
    no warnings 'redefine';
    local *Mojo::UserAgent::start_p = sub ($self, $tx) {
        $captured = $tx;
        return Mojo::Promise->resolve(_fake_tx());
    };

    subtest 'AC1+AC2: Idempotency-Key in header, stripped from form body' => sub {
        $captured = undef;
        $svc->create_payment_intent_async({
            amount           => 1000,
            currency         => 'usd',
            _idempotency_key => 'k1',
        })->wait;

        is $captured->req->headers->header('Idempotency-Key'), 'k1',
            'AC1: Idempotency-Key: k1 header present on request';
        is $captured->req->body_params->param('amount'), 1000,
            'AC2: amount=1000 present in form body';
        ok !defined $captured->req->body_params->param('_idempotency_key'),
            'AC2: _idempotency_key absent from form body';
    };

    subtest 'no _idempotency_key: Idempotency-Key header absent' => sub {
        $captured = undef;
        $svc->create_payment_intent_async({
            amount   => 500,
            currency => 'usd',
        })->wait;

        ok !defined $captured->req->headers->header('Idempotency-Key'),
            'Idempotency-Key header absent when key not supplied';
    };

    subtest 'caller hashref not mutated' => sub {
        my %params = (amount => 2000, currency => 'usd', _idempotency_key => 'k2');
        $svc->create_payment_intent_async(\%params)->wait;
        ok exists $params{_idempotency_key},
            '_idempotency_key still in caller hashref after call';
    };

    subtest 'promise resolves to decoded JSON' => sub {
        my $result;
        $svc->create_payment_intent_async({ amount => 1000, currency => 'usd' })
            ->then(sub ($r) { $result = $r })
            ->wait;
        is_deeply $result, { id => 'pi_b1_fake' },
            'promise resolves to decoded JSON hash';
    };
}

done_testing;
