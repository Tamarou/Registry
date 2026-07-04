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
use Registry::DAO;
use Registry::DAO::Payment;
use Registry::DAO::Tenant;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::WorkflowSteps::Payment;
use Registry::DAO::User;
use Registry::DAO::Family;
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Location;

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

# -----------------------------------------------------------------------
# B3: Workflow step reuses the run's payment row on double-submit;
#     retry (decline) path rotates the idempotency token.
# -----------------------------------------------------------------------

# B3 fixtures: stripe-ready tenant, tenant schema, session with pricing,
# parent user, workflow with payment step.

my $b3_slug = 'b3_idem_' . $$;

Registry::DAO::Tenant->create($db, {
    name                      => 'B3 Idempotency Tenant',
    slug                      => $b3_slug,
    stripe_connect_account_id => 'acct_b3test',
    stripe_charges_enabled    => 1,
    stripe_details_submitted  => 1,
});
$db->query('SELECT clone_schema(?)', $b3_slug);

my $b3dao = Registry::DAO->new(url => $test_db->uri, schema => $b3_slug);
my $b3db  = $b3dao->db;

my $b3_location = Registry::DAO::Location->create($b3db, {
    name         => 'B3 Studio',
    address_info => { street_address => '1 B3 St', city => 'Testville', state => 'TX', postal_code => '78701' },
    metadata     => {},
});

my $b3_teacher = Registry::DAO::User->create($b3db, {
    name      => 'B3 Teacher',
    username  => 'b3teacher_' . $$,
    email     => "b3teacher_$$\@test.com",
    user_type => 'staff',
});

my $b3_project = Registry::DAO::Project->create($b3db, {
    name     => 'B3 Summer Camp',
    metadata => {},
});

my $b3_event = Registry::DAO::Event->create($b3db, {
    time        => '2026-07-01 10:00:00',
    duration    => 120,
    location_id => $b3_location->id,
    project_id  => $b3_project->id,
    teacher_id  => $b3_teacher->id,
    capacity    => 20,
    metadata    => {},
});

my $b3_session = Registry::DAO::Session->create($b3db, {
    name       => 'B3 Week',
    start_date => '2026-07-01',
    end_date   => '2026-07-07',
    status     => 'published',
    capacity   => 20,
    metadata   => {},
});
$b3_session->add_events($b3db, $b3_event->id);

Registry::DAO::PricingPlan->create($b3db, {
    session_id => $b3_session->id,
    plan_name  => 'Standard',
    plan_type  => 'standard',
    amount     => 100.00,
});

my $b3_parent = Registry::DAO::User->create($b3db, {
    email     => "b3parent_$$\@example.com",
    username  => 'b3parent_' . $$,
    name      => 'B3 Parent',
    user_type => 'parent',
});

my $b3_child = Registry::DAO::Family->add_child($b3db, $b3_parent->id, {
    child_name        => 'B3 Child',
    birth_date        => '2018-03-15',
    grade             => '3',
    medical_info      => {},
    emergency_contact => { name => 'Emergency', phone => '555-0199' },
});

my $b3_workflow = Registry::DAO::Workflow->create($b3db, {
    name        => 'B3 Test Workflow',
    slug        => 'b3-workflow-' . $$,
    description => 'B3 idempotency test workflow',
});

my $b3_step_row = Registry::DAO::WorkflowStep->create($b3db, {
    workflow_id => $b3_workflow->id,
    slug        => 'payment',
    class       => 'Registry::DAO::WorkflowSteps::Payment',
    description => 'Payment step',
});

Registry::DAO::WorkflowStep->create($b3db, {
    workflow_id => $b3_workflow->id,
    slug        => 'complete',
    class       => 'Registry::DAO::WorkflowStep',
    description => 'Completion step',
    depends_on  => $b3_step_row->id,
});

$b3_workflow->update($b3db, { first_step => 'payment' }, { id => $b3_workflow->id });

sub make_b3_run {
    my $run = $b3_workflow->new_run($b3db);
    $run->update_data($b3db, {
        user_id            => $b3_parent->id,
        children           => [ {
            id         => $b3_child->id,
            first_name => 'B3',
            last_name  => 'Child',
            birth_date => '2018-03-15',
            grade      => '3',
        } ],
        session_selections => { $b3_child->id => $b3_session->id },
        enrollment_items   => [ { child_id => $b3_child->id, session_id => $b3_session->id } ],
        __tenant_slug      => $b3_slug,
    });
    return $run;
}

sub get_b3_step {
    return $b3_workflow->get_step($b3db, { slug => 'payment' });
}

{
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_b3fake';

    subtest 'B3-AC1: double agreeTerms submit yields one payment row, identical idempotency key' => sub {
        my $run  = make_b3_run();
        my $step = get_b3_step();

        my @captured_keys;
        {
            no warnings 'redefine';
            local *Registry::Service::Stripe::create_payment_intent = sub ($s, $p) {
                push @captured_keys, $p->{_idempotency_key};
                return { id => 'pi_b3_ac1', client_secret => 'cs_b3_ac1' };
            };

            $step->process($b3db, { agreeTerms => 1 }, $run);
            my $first_payment_id = $run->data->{payment_id};
            ok $first_payment_id, 'payment_id set after first submit';

            $step->process($b3db, { agreeTerms => 1 }, $run);
            my $second_payment_id = $run->data->{payment_id};
            is $second_payment_id, $first_payment_id,
                'payment_id unchanged after second submit (same row reused)';
        }

        my $count = $b3db->query(
            "SELECT COUNT(*) FROM payments WHERE metadata->>'workflow_run_id' = ?",
            $run->id
        )->array->[0];
        is $count, 1,
            'AC1: exactly one payment row for this workflow run after double submit';

        is scalar @captured_keys, 2,
            'create_payment_intent called once per submit';
        is $captured_keys[0], $captured_keys[1],
            'AC1: both calls sent identical idempotency key';
    };

    subtest 'B3-AC2: decline then retry rotates idempotency token (new key, same row)' => sub {
        my $run  = make_b3_run();
        my $step = get_b3_step();

        my $orig_key;
        {
            no warnings 'redefine';
            local *Registry::Service::Stripe::create_payment_intent = sub ($s, $p) {
                $orig_key //= $p->{_idempotency_key};
                return { id => 'pi_b3_ac2_orig', client_secret => 'cs_b3_ac2_orig' };
            };
            $step->process($b3db, { agreeTerms => 1 }, $run);
        }

        ok defined $orig_key, 'original idempotency key captured from first intent';

        my $retry_key;
        {
            no warnings 'redefine';
            local *Registry::Service::Stripe::retrieve_payment_intent = sub ($s, $id) {
                return {
                    status             => 'requires_payment_method',
                    last_payment_error => { message => 'Your card was declined.' },
                };
            };
            local *Registry::Service::Stripe::create_payment_intent = sub ($s, $p) {
                $retry_key = $p->{_idempotency_key};
                return { id => 'pi_b3_ac2_retry', client_secret => 'cs_b3_ac2_retry' };
            };
            $step->process($b3db, { payment_intent_id => 'pi_b3_ac2_orig' }, $run);
        }

        ok defined $retry_key, 'retry idempotency key captured from retry intent';
        isnt $retry_key, $orig_key,
            'AC2: retry used a different idempotency key (token was rotated for new charge)';

        my $count = $b3db->query(
            "SELECT COUNT(*) FROM payments WHERE metadata->>'workflow_run_id' = ?",
            $run->id
        )->array->[0];
        is $count, 1,
            'AC2: still exactly one payment row after decline and retry';
    };
}

# -----------------------------------------------------------------------
# B3 review-fix subtests: pin the reuse-path clauses the TIER_2 mutation
# pass proved undefended (m1 completed->new-row, m2 payment_items refresh,
# m4 amount refresh), and the behavior fixes from the confirmed findings:
# rotation only on true declines, superseded-intent cancellation, and
# intent-ownership verification on the parent-return callback.
# -----------------------------------------------------------------------
{
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_b3fake';

    subtest 'B3-fix m1: completed payment starts a NEW row (second purchase)' => sub {
        my $run  = make_b3_run();
        my $step = get_b3_step();

        no warnings 'redefine';
        my $seq = 0;
        local *Registry::Service::Stripe::create_payment_intent = sub ($s, $p) {
            $seq++;
            return { id => "pi_m1_$seq", client_secret => "cs_m1_$seq" };
        };

        $step->process($b3db, { agreeTerms => 1 }, $run);
        my $first = $run->data->{payment_id};
        ok $first, 'first purchase created a payment row';

        $b3db->update('payments', { status => 'completed' }, { id => $first });

        $step->process($b3db, { agreeTerms => 1 }, $run);
        my $second = $run->data->{payment_id};
        isnt $second, $first, 'completed row is NOT reused (second purchase)';

        my $count = $b3db->query(
            "SELECT COUNT(*) FROM payments WHERE metadata->>'workflow_run_id' = ?",
            $run->id
        )->array->[0];
        is $count, 2, 'two rows: settled purchase plus the new one';
    };

    subtest 'B3-fix m2: identical resubmit does not duplicate payment_items' => sub {
        my $run  = make_b3_run();
        my $step = get_b3_step();

        no warnings 'redefine';
        local *Registry::Service::Stripe::create_payment_intent = sub ($s, $p) {
            return { id => 'pi_m2', client_secret => 'cs_m2' };
        };

        $step->process($b3db, { agreeTerms => 1 }, $run);
        $step->process($b3db, { agreeTerms => 1 }, $run);

        my $items = $b3db->query(
            'SELECT COUNT(*) FROM payment_items WHERE payment_id = ?',
            $run->data->{payment_id}
        )->array->[0];
        is $items, 1, 'line items refreshed in place, not appended';
    };

    subtest 'B3-fix m4: changed cart refreshes amount, rotates key, cancels superseded intent' => sub {
        my $run  = make_b3_run();
        my $step = get_b3_step();

        my (@keys, @cancelled);
        no warnings 'redefine';
        my $seq = 0;
        local *Registry::Service::Stripe::create_payment_intent = sub ($s, $p) {
            $seq++;
            push @keys, $p->{_idempotency_key};
            return { id => "pi_m4_$seq", client_secret => "cs_m4_$seq" };
        };
        local *Registry::Service::Stripe::cancel_payment_intent = sub ($s, $intent_id) {
            push @cancelled, $intent_id;
            return { id => $intent_id, status => 'canceled' };
        };

        $step->process($b3db, { agreeTerms => 1 }, $run);
        my $payment_id = $run->data->{payment_id};
        my $amount1    = Registry::DAO::Payment->find($b3db, { id => $payment_id })->amount;
        cmp_ok $amount1, '==', 100, 'first submit: single-child cart totals 100';

        # Parent goes back and adds a second child before resubmitting.
        my $m4_child2 = Registry::DAO::Family->add_child($b3db, $b3_parent->id, {
            child_name        => 'B3 Second Child',
            birth_date        => '2019-06-01',
            grade             => '2',
            medical_info      => {},
            emergency_contact => { name => 'Emergency', phone => '555-0199' },
        });
        my $children = [
            @{ $run->data->{children} },
            { id => $m4_child2->id, first_name => 'B3Second', last_name => 'Child',
              birth_date => '2019-06-01', grade => '2' },
        ];
        $run->update_data($b3db, {
            children           => $children,
            session_selections => {
                %{ $run->data->{session_selections} },
                $m4_child2->id => $b3_session->id,
            },
            enrollment_items   => [
                @{ $run->data->{enrollment_items} },
                { child_id => $m4_child2->id, session_id => $b3_session->id },
            ],
        });

        $step->process($b3db, { agreeTerms => 1 }, $run);

        is $run->data->{payment_id}, $payment_id, 'same payment row reused';
        my $refreshed = Registry::DAO::Payment->find($b3db, { id => $payment_id });
        cmp_ok $refreshed->amount, '==', 200, 'amount refreshed to the new cart total';
        is scalar @keys, 2, 'one intent creation per submit';
        isnt $keys[1], $keys[0],
            'changed cart rotated the idempotency key (fresh charge, not a doomed replay)';
        is_deeply \@cancelled, ['pi_m4_1'],
            'superseded intent was cancelled (at most one confirmable intent)';
    };

    subtest 'B3-fix: requires_action callback neither rotates nor mints a new intent' => sub {
        my $run  = make_b3_run();
        my $step = get_b3_step();

        my @keys;
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_payment_intent = sub ($s, $p) {
            push @keys, $p->{_idempotency_key};
            return { id => 'pi_ra_1', client_secret => 'cs_ra_1' };
        };

        $step->process($b3db, { agreeTerms => 1 }, $run);
        is scalar @keys, 1, 'initial intent created';

        local *Registry::Service::Stripe::retrieve_payment_intent = sub ($s, $intent_id) {
            return {
                id       => 'pi_ra_1',
                status   => 'requires_action',
                metadata => { payment_id => $run->data->{payment_id} },
            };
        };

        my $result = $step->process($b3db, { payment_intent_id => 'pi_ra_1' }, $run);

        is scalar @keys, 1,
            'no replacement intent minted while the customer is mid-authentication';
        ok $result->{data}{processing},
            'callback surfaces an in-progress state, not a decline retry';
        my $token = Registry::DAO::Payment->find($b3db, { id => $run->data->{payment_id} })
            ->metadata->{idempotency_token};
        like $keys[0], qr/\Q$token\E\z/,
            'idempotency token unchanged (no rotation on requires_action)';
    };

    subtest 'B3-fix: succeeded intent not owned by this payment is rejected' => sub {
        my $run  = make_b3_run();
        my $step = get_b3_step();

        no warnings 'redefine';
        local *Registry::Service::Stripe::create_payment_intent = sub ($s, $p) {
            return { id => 'pi_own_mine', client_secret => 'cs_own' };
        };

        $step->process($b3db, { agreeTerms => 1 }, $run);
        my $payment_id = $run->data->{payment_id};

        # Attacker replays a succeeded intent that belongs to a DIFFERENT payment.
        local *Registry::Service::Stripe::retrieve_payment_intent = sub ($s, $intent_id) {
            return {
                id       => 'pi_foreign',
                status   => 'succeeded',
                metadata => { payment_id => 'not-this-payment' },
            };
        };
        local *Registry::Service::Stripe::cancel_payment_intent = sub ($s, $intent_id) {
            return { id => $intent_id, status => 'canceled' };
        };

        $step->process($b3db, { payment_intent_id => 'pi_foreign' }, $run);

        my $payment = Registry::DAO::Payment->find($b3db, { id => $payment_id });
        isnt $payment->status, 'completed',
            'foreign succeeded intent does not complete this payment';
        my $enrollments = $b3db->query(
            'SELECT COUNT(*) FROM enrollments WHERE payment_id = ?', $payment_id
        )->array->[0];
        is $enrollments, 0, 'no enrollment granted for a foreign charge';
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
        amount                   => 100,
        status                   => 'pending',
        stripe_payment_intent_id => 'pi_w1_guard',
        metadata                 => {},
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
