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

# -----------------------------------------------------------------------
# B2: Payment->create generates a stable idempotency token; create_payment_intent
# threads it as _idempotency_key; rotate_idempotency_token cycles it.
# -----------------------------------------------------------------------

use Test::Registry::DB;
use Registry::DAO::Payment;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;    # Registry::DAO
my $db      = $dao->db;        # Mojo::Pg::Database

my $b2_user_id = $db->query(q{
    INSERT INTO registry.users (username, passhash)
    VALUES ('b2_idem_test', 'nohash')
    RETURNING id
})->hash->{id};

ok $b2_user_id, "created test user for B2 subtests (id=$b2_user_id)";

my $UUID_RE = qr/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

subtest 'AC3: auto-generated token survives -json/ADJUST round-trip on reload' => sub {
    my $payment = Registry::DAO::Payment->create($db, {
        user_id  => $b2_user_id,
        amount   => 10.00,
        metadata => {},
    });

    my $token = $payment->metadata->{idempotency_token};
    ok defined $token, 'idempotency_token set on freshly created payment';
    like $token, $UUID_RE, 'token is UUID-shaped';

    # Reload via Payment->find to prove it survived the -json/ADJUST round-trip
    my $reloaded = Registry::DAO::Payment->find($db, { id => $payment->id });
    is $reloaded->metadata->{idempotency_token}, $token,
        'token unchanged after reload (-json/ADJUST round-trip confirmed)';
};

subtest 'explicit idempotency_token on create is preserved, not overwritten' => sub {
    my $explicit = 'explicit-token-b2-test';
    my $payment  = Registry::DAO::Payment->create($db, {
        user_id  => $b2_user_id,
        amount   => 20.00,
        metadata => { idempotency_token => $explicit },
    });

    my $reloaded = Registry::DAO::Payment->find($db, { id => $payment->id });
    is $reloaded->metadata->{idempotency_token}, $explicit,
        'explicit token preserved after create + reload';
};

subtest 'AC1: both create_payment_intent calls send identical "pi-create:<token>" key' => sub {
    my $payment = Registry::DAO::Payment->create($db, {
        user_id  => $b2_user_id,
        amount   => 30.00,
        metadata => {},
    });

    my $token = $payment->metadata->{idempotency_token};
    ok defined $token, 'payment has idempotency_token';

    my @captured_keys;
    {
        no warnings 'redefine';
        local $ENV{STRIPE_SECRET_KEY} = 'sk_test_b2fake';
        # DAO's create_payment_intent calls stripe_client->create_payment_intent (sync);
        # intercept at that level, matching the refund test pattern.
        local *Registry::Service::Stripe::create_payment_intent = sub ($s, $p) {
            push @captured_keys, $p->{_idempotency_key};
            return { id => 'pi_b2_fake', client_secret => 'sec_b2' };
        };
        $payment->create_payment_intent($db);
        $payment->create_payment_intent($db);
    }

    is scalar @captured_keys, 2, 'create_payment_intent called twice';
    is $captured_keys[0], "pi-create:$token",
        "first call: exact key is 'pi-create:$token'";
    is $captured_keys[1], "pi-create:$token",
        "second call: same key 'pi-create:$token'";
    is $captured_keys[0], $captured_keys[1], 'AC1: both calls sent identical idempotency key';
};

subtest 'AC2: rotate_idempotency_token changes token, persists, next intent uses new key' => sub {
    my $payment = Registry::DAO::Payment->create($db, {
        user_id  => $b2_user_id,
        amount   => 40.00,
        metadata => {},
    });

    my $orig_token = $payment->metadata->{idempotency_token};
    ok defined $orig_token, 'original token set';

    $payment->rotate_idempotency_token($db);

    my $new_token = $payment->metadata->{idempotency_token};
    isnt $new_token, $orig_token, 'token changed after rotation';
    like $new_token, $UUID_RE, 'new token is UUID-shaped';

    my $reloaded = Registry::DAO::Payment->find($db, { id => $payment->id });
    is $reloaded->metadata->{idempotency_token}, $new_token,
        'rotated token persisted to DB (reload confirms)';

    my $captured_key;
    {
        no warnings 'redefine';
        local $ENV{STRIPE_SECRET_KEY} = 'sk_test_b2fake';
        local *Registry::Service::Stripe::create_payment_intent = sub ($s, $p) {
            $captured_key = $p->{_idempotency_key};
            return { id => 'pi_b2_rot', client_secret => 'sec_rot' };
        };
        $payment->create_payment_intent($db);
    }

    is $captured_key, "pi-create:$new_token",
        'AC2: post-rotation intent sends new pi-create:<new_token> key';
};

done_testing;
