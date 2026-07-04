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

done_testing;
