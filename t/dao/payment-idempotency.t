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
use Test::Registry::Async qw( settle );

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
use Test::Registry::PricingProbe qw( state_platform_terms );
use Test::Registry::Fixtures;
use Registry::DAO;
use Registry::DAO::Payment;
use Registry::DAO::Tenant;
use Registry::DAO::FamilyMember;
use Registry::DAO::WorkflowRun;
use Test::Registry::Helpers qw( days_from_now );
use Test::Registry::Sessions qw( make_session session_offer held_cart );

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;    # Registry::DAO
my $db      = $dao->db;        # Mojo::Pg::Database
my $platform = Test::Registry::Fixtures::platform_seller($db);
state_platform_terms( $db, $platform, { rate => 0 } );

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
        amount_cents => 1000,
        metadata => { tenant_slug => $platform },
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
        amount_cents => 2000,
        metadata => { idempotency_token => $explicit },
    });

    my $reloaded = Registry::DAO::Payment->find($db, { id => $payment->id });
    is $reloaded->metadata->{idempotency_token}, $explicit,
        'explicit token preserved after create + reload';
};

subtest 'AC1: both create_payment_intent calls send identical "pi-create:<token>" key' => sub {
    my $payment = Registry::DAO::Payment->create($db, {
        user_id  => $b2_user_id,
        amount_cents => 3000,
        metadata => { tenant_slug => $platform },
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
        amount_cents => 4000,
        metadata => { tenant_slug => $platform },
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

# -----------------------------------------------------------------------
# B3: The session cart's payment step reuses the run's payment row on a
#     double submit, and never charges a paid or changed cart again.
# -----------------------------------------------------------------------

# B3 fixtures: registry sells its own sessions, on a ready account; a parent
# with a child, and a cart held and owing at its payment step.
$db->query( q{UPDATE registry.tenants SET stripe_charges_enabled = TRUE, stripe_details_submitted = TRUE
               WHERE slug = ?}, $platform );

my $b3_parent = Test::Registry::Fixtures::create_user( $db, {
    username => 'b3parent', name => 'B3 Parent', email => 'b3parent@example.com' } );
my $b3_child = Registry::DAO::FamilyMember->create( $db, {
    family_id => $b3_parent->id, child_name => 'B3 Child', birth_date => '2018-03-15' } );

sub make_b3_cart {
    my $session = make_session( $db, days => [ map { days_from_now($_) } 30 .. 32 ] );
    my $version = session_offer( $db, $session, price_cents => 10000 );
    return held_cart( $dao, $b3_parent->id, [ $b3_child->id, $session->id, $version->id, 'pay' ] );
}

sub b3_payment_id ($run) {
    Registry::DAO::WorkflowRun->find( $db, { id => $run->id } )->data->{owed_payment_id};
}
sub b3_rows ($run) {
    $db->query( "SELECT COUNT(*) FROM payments WHERE metadata->>'workflow_run_id' = ?", $run->id )->array->[0];
}

{
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_b3fake';

    subtest 'B3-AC1: double submit yields one payment row, identical idempotency key' => sub {
        my ( $run, $step ) = make_b3_cart();

        my @captured_keys;
        {
            no warnings 'redefine';
            local *Registry::Service::Stripe::create_payment_intent_async = sub ($s, $p) {
                push @captured_keys, $p->{_idempotency_key};
                return Mojo::Promise->resolve(
                    { id => 'pi_b3_ac1', client_secret => 'cs_b3_ac1' });
            };

            settle($run->process($db, $step, {}));
            my $first_payment_id = b3_payment_id($run);
            ok $first_payment_id, 'owed_payment_id set after first submit';

            settle($run->process($db, $step, {}));
            is b3_payment_id($run), $first_payment_id,
                'owed_payment_id unchanged after second submit (same row reused)';
        }

        is b3_rows($run), 1,
            'AC1: exactly one payment row for this workflow run after double submit';
        is scalar @captured_keys, 2,
            'create_payment_intent called once per submit';
        is $captured_keys[0], $captured_keys[1],
            'AC1: both calls sent identical idempotency key';
    };

    subtest 'B3-AC2: a declined card is retried as a new charge under a new key' => sub {
        my ( $run, $step ) = make_b3_cart();

        my @keys;
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_payment_intent_async = sub ($s, $p) {
            push @keys, $p->{_idempotency_key};
            return Mojo::Promise->resolve(
                { id => 'pi_b3_ac2_' . @keys, client_secret => 'cs_b3_ac2' });
        };
        settle($run->process($db, $step, {}));
        my $declined = b3_payment_id($run);

        {
            local *Registry::Service::Stripe::retrieve_payment_intent_async = sub ($s, $id) {
                return Mojo::Promise->resolve({
                    id                 => 'pi_b3_ac2_1',
                    status             => 'requires_payment_method',
                    last_payment_error => { message => 'Your card was declined.' },
                });
            };
            my $out = settle($run->process($db, $step, { payment_intent_id => 'pi_b3_ac2_1' }));
            is_deeply $out->{errors}, ['Your card was declined.'], 'the decline is shown';
        }
        is Registry::DAO::Payment->find( $db, { id => $declined } )->status, 'failed',
            'the declined charge is recorded as failed';

        my @cancelled;
        local *Registry::Service::Stripe::cancel_payment_intent_async = sub ($s, $id, $p = {}) {
            push @cancelled, $id;
            return Mojo::Promise->resolve({ id => $id, status => 'canceled' });
        };
        settle($run->process($db, $step, {}));
        is_deeply \@cancelled, ['pi_b3_ac2_1'], 'the declined intent is cancelled before the retry';
        isnt b3_payment_id($run), $declined, 'the retry is its own payment row';
        is scalar @keys, 2, 'one intent per attempt';
        isnt $keys[1], $keys[0],
            'AC2: retry used a different idempotency key (a fresh charge, not a replay of the declined one)';
    };

    subtest 'B3-fix m1: a paid cart is handed on, never charged again' => sub {
        my ( $run, $step ) = make_b3_cart();

        no warnings 'redefine';
        my $seq = 0;
        local *Registry::Service::Stripe::create_payment_intent_async = sub ($s, $p) {
            $seq++;
            return Mojo::Promise->resolve(
                { id => "pi_m1_$seq", client_secret => "cs_m1_$seq" });
        };

        settle($run->process($db, $step, {}));
        my $first = b3_payment_id($run);
        $db->update('payments', { status => 'completed' }, { id => $first });

        my $out = settle($step->process($db, {}, $run));
        ok !$out->{errors} && !$out->{next_step}, 'the step hands the run on' or diag explain $out;
        is $seq, 1, 'and makes no second intent';
        is b3_rows($run), 1, 'nor a second row';
    };

    subtest 'B3-fix m4: a cart changed after its charge started is refused' => sub {
        my ( $run, $step ) = make_b3_cart();

        my @keys;
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_payment_intent_async = sub ($s, $p) {
            push @keys, $p->{_idempotency_key};
            return Mojo::Promise->resolve({ id => 'pi_m4_' . @keys, client_secret => 'cs_m4' });
        };

        settle($run->process($db, $step, {}));
        my $payment_id = b3_payment_id($run);
        cmp_ok( Registry::DAO::Payment->find($db, { id => $payment_id })->amount_cents, q{==}, 10000,
            q{first submit: single-child cart totals 10000 cents} );

        # The owed lines change under the started charge (another child's line).
        my $owed = $run->data->{owed_payment};
        $owed->{lines}[0]{family_member_id} = '00000000-0000-4000-8000-000000000001';
        $run->update_data($db, { owed_payment => $owed });

        my $out = settle($run->process($db, $step, {}));
        is_deeply $out->{errors}, ['What is owed changed after this payment was started.'], 'refused';
        is scalar @keys, 1, 'no intent is made for the changed cart';
        is b3_rows($run), 1, 'and no second row';
    };

    subtest 'B3-fix: requires_action callback neither rotates nor mints a new intent' => sub {
        my ( $run, $step ) = make_b3_cart();

        my @keys;
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_payment_intent_async = sub ($s, $p) {
            push @keys, $p->{_idempotency_key};
            return Mojo::Promise->resolve({ id => 'pi_ra_1', client_secret => 'cs_ra_1' });
        };

        settle($run->process($db, $step, {}));
        is scalar @keys, 1, 'initial intent created';

        local *Registry::Service::Stripe::retrieve_payment_intent_async = sub ($s, $intent_id) {
            return Mojo::Promise->resolve({
                id       => 'pi_ra_1',
                status   => 'requires_action',
                metadata => { payment_id => b3_payment_id($run) },
            });
        };

        settle($run->process($db, $step, { payment_intent_id => 'pi_ra_1' }));

        is scalar @keys, 1,
            'no replacement intent minted on the return';
        my $token = Registry::DAO::Payment->find($db, { id => b3_payment_id($run) })
            ->metadata->{idempotency_token};
        like $keys[0], qr/\Q$token\E\z/,
            'idempotency token unchanged (no rotation on requires_action)';
    };

    subtest 'B3-fix: succeeded intent not owned by this payment is rejected' => sub {
        my ( $run, $step ) = make_b3_cart();

        no warnings 'redefine';
        local *Registry::Service::Stripe::create_payment_intent_async = sub ($s, $p) {
            return Mojo::Promise->resolve({ id => 'pi_own_mine', client_secret => 'cs_own' });
        };

        settle($run->process($db, $step, {}));
        my $payment_id = b3_payment_id($run);

        # Attacker replays a succeeded intent that belongs to a DIFFERENT payment.
        local *Registry::Service::Stripe::retrieve_payment_intent_async = sub ($s, $intent_id) {
            return Mojo::Promise->resolve({
                id       => 'pi_foreign',
                status   => 'succeeded',
                metadata => { payment_id => 'not-this-payment' },
            });
        };

        my $out = settle($run->process($db, $step, { payment_intent_id => 'pi_foreign' }));

        ok $out->{errors}, 'the return is refused';
        isnt Registry::DAO::Payment->find($db, { id => $payment_id })->status, 'completed',
            'foreign succeeded intent does not complete this payment';
        is $db->query( 'SELECT COUNT(*) FROM entitlements WHERE payment_id = ?', $payment_id )->array->[0], 0,
            'no entitlement granted for a foreign charge';
        is Registry::DAO::WorkflowRun->find( $db, { id => $run->id } )->next_step($db)->slug, 'payment',
            'and the run stays at its payment';
    };
}

# -----------------------------------------------------------------------
# Leg W1: process_payment only completes when the intent's captured amount
# matches the payment row (guards against a stale intent completing a
# refreshed, differently-priced cart).
# -----------------------------------------------------------------------
subtest 'W1: process_payment rejects a succeeded intent whose amount mismatches the row' => sub {
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_w1fake';

    my $payment = Registry::DAO::Payment->create($db, {
        user_id                  => $b2_user_id,
        amount_cents             => 10000,
        status                   => 'pending',
        stripe_payment_intent_id => 'pi_w1_guard',
        metadata                 => { tenant_slug => $platform },
    });
    $payment = Registry::DAO::Payment->find($db, { id => $payment->id });

    no warnings 'redefine';
    my $intent_amount;
    local *Registry::Service::Stripe::retrieve_payment_intent = sub ($s, $intent_id) {
        return {
            id       => 'pi_w1_guard',
            status   => 'succeeded',
            amount   => $intent_amount,
            metadata => { payment_id => $payment->id },
        };
    };

    $intent_amount = 5000;    # row is $100 = 10000 cents
    my $bad = $payment->process_payment($db, 'pi_w1_guard');
    ok !$bad->{success}, 'mismatched amount is not honored';
    my $row = Registry::DAO::Payment->find($db, { id => $payment->id });
    isnt $row->status, 'completed', 'payment not completed on amount mismatch';

    $intent_amount = 10000;
    my $good = $payment->process_payment($db, 'pi_w1_guard');
    ok $good->{success}, 'matching amount completes as before';
};

# ---------------------------------------------------------------------------
# Leg B4: sync wrappers must return the resolved API response.
# Mojo::Promise::wait returns 1 (or undef inside a running ioloop), never the
# resolved value, so `return $p->wait` in a sync wrapper returns garbage. These
# subtests exercise the REAL sync wrappers end-to-end against an intercepted
# transport (Mojo::UserAgent::start_p) -- never the wrapper itself -- so a
# regression back to `->wait` cannot hide behind a mocked wrapper.
# ---------------------------------------------------------------------------
{
    my $b4_svc = Registry::Service::Stripe->new(api_key => 'sk_test_fake_b4');

    sub _fake_tx_json ($json, $code = 200) {
        my $tx = Mojo::Transaction::HTTP->new;
        $tx->res->code($code);
        $tx->res->body($json);
        return $tx;
    }

    no warnings 'redefine';

    subtest 'B4: create_payment_intent (sync) returns the decoded intent hash' => sub {
        local *Mojo::UserAgent::start_p = sub ($self, $tx) {
            return Mojo::Promise->resolve(
                _fake_tx_json('{"id":"pi_b4_sync","client_secret":"cs_b4"}'));
        };
        my $intent = $b4_svc->create_payment_intent({ amount => 1000, currency => 'usd' });
        is ref $intent, 'HASH', 'sync create_payment_intent returns a hashref';
        is $intent->{id}, 'pi_b4_sync', 'hashref is the decoded API response';
        is $intent->{client_secret}, 'cs_b4', 'all response fields present';
    };

    subtest 'B4: create_refund (sync) returns the decoded refund hash' => sub {
        local *Mojo::UserAgent::start_p = sub ($self, $tx) {
            return Mojo::Promise->resolve(
                _fake_tx_json('{"id":"re_b4_sync","status":"succeeded"}'));
        };
        my $refund = $b4_svc->create_refund({ payment_intent => 'pi_x' });
        is ref $refund, 'HASH', 'sync create_refund returns a hashref';
        is $refund->{id}, 're_b4_sync', 'hashref is the decoded refund';
        is $refund->{status}, 'succeeded', 'refund status present';
    };

    subtest 'B4: sync wrapper preserves the croak message format on API errors' => sub {
        local *Mojo::UserAgent::start_p = sub ($self, $tx) {
            return Mojo::Promise->resolve(_fake_tx_json(
                '{"error":{"message":"Your card was declined.","type":"card_error","code":"card_declined"}}',
                402));
        };
        my $err = do {
            local $@;
            eval { $b4_svc->create_payment_intent({ amount => 1000, currency => 'usd' }) };
            $@;
        };
        like $err, qr/Stripe card_error: Your card was declined\. \(card_declined\)/,
            'error message format preserved (matches is_card_error contract)';
    };
}

done_testing;
