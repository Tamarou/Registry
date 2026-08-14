#!/usr/bin/env perl
# ABOUTME: Tests for refund_application_fee_for_tenant resolver in Registry::PriceOps::RevenueShare.
# ABOUTME: Covers linked-plan flag, NULL FK fallback, platform-plan fallback, die cases, DAO coercion, and Payment->refund/refund_async Connect-param encoding.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Mojo::JSON qw(decode_json);
use Registry::PriceOps::RevenueShare qw(refund_application_fee_for_tenant);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;     # Registry::DAO
my $db      = $dao->db;         # Mojo::Pg::Database

# Find a seeded tenant linked to a tenant-scoped plan (same query as revenue-share.t).
my $seeded_slug = $db->query(q{
    SELECT t.slug
      FROM registry.tenants t
      JOIN registry.pricing_plans p ON p.id = t.platform_pricing_plan_id
     WHERE p.pricing_model_type = 'percentage'
       AND p.plan_scope = 'tenant'
     LIMIT 1
})->hash->{slug};

ok $seeded_slug, "found a seeded tenant linked to a plan (slug=$seeded_slug)";

subtest 'linked plan without refund_application_fee key defaults to true (1)' => sub {
    # Strip the key from pricing_configuration (no-op when absent) to guarantee
    # the absent-key path is exercised, then restore the original config.
    my $plan_id = $db->query(q{
        SELECT platform_pricing_plan_id FROM registry.tenants WHERE slug = ?
    }, $seeded_slug)->hash->{platform_pricing_plan_id};

    my $saved = $db->query(q{
        SELECT pricing_configuration FROM registry.pricing_plans WHERE id = ?
    }, $plan_id)->hash;

    $db->query(q{
        UPDATE registry.pricing_plans
           SET pricing_configuration = pricing_configuration - 'refund_application_fee'
         WHERE id = ?
    }, $plan_id);

    my $flag = refund_application_fee_for_tenant($db, $seeded_slug);
    is $flag, 1, 'absent key -> default true (1)';

    $db->query(q{
        UPDATE registry.pricing_plans SET pricing_configuration = ? WHERE id = ?
    }, $saved->{pricing_configuration}, $plan_id);
};

subtest 'linked plan with refund_application_fee=false returns 0' => sub {
    my $plan_id = $db->query(q{
        SELECT platform_pricing_plan_id FROM registry.tenants WHERE slug = ?
    }, $seeded_slug)->hash->{platform_pricing_plan_id};

    my $saved = $db->query(q{
        SELECT pricing_configuration FROM registry.pricing_plans WHERE id = ?
    }, $plan_id)->hash;

    $db->query(q{
        UPDATE registry.pricing_plans
           SET pricing_configuration = pricing_configuration
                   || '{"refund_application_fee": false}'::jsonb
         WHERE id = ?
    }, $plan_id);

    my $flag = refund_application_fee_for_tenant($db, $seeded_slug);
    is $flag, 0, 'refund_application_fee=false -> returns 0';

    $db->query(q{
        UPDATE registry.pricing_plans SET pricing_configuration = ? WHERE id = ?
    }, $saved->{pricing_configuration}, $plan_id);
};

subtest 'Registry::DAO coercion - accepts DAO object as well as raw db handle' => sub {
    my $flag = refund_application_fee_for_tenant($dao, $seeded_slug);
    is $flag, 1, 'DAO coercion: result is the same (absent key -> 1)';
};

subtest 'NULL platform_pricing_plan_id falls back to platform default -> 1' => sub {
    my $saved = $db->query(q{
        SELECT platform_pricing_plan_id FROM registry.tenants WHERE slug = ?
    }, $seeded_slug)->hash->{platform_pricing_plan_id};

    $db->query(q{
        UPDATE registry.tenants SET platform_pricing_plan_id = NULL WHERE slug = ?
    }, $seeded_slug);

    my $flag = refund_application_fee_for_tenant($db, $seeded_slug);
    is $flag, 1, 'NULL FK -> platform default (no key set) -> 1';

    $db->query(q{
        UPDATE registry.tenants SET platform_pricing_plan_id = ? WHERE slug = ?
    }, $saved, $seeded_slug);
};

subtest 'platform default plan with refund_application_fee=false and NULL FK -> 0' => sub {
    # Null the tenant FK, set the platform default plan's key to false, verify 0, restore.
    my $saved_fk = $db->query(q{
        SELECT platform_pricing_plan_id FROM registry.tenants WHERE slug = ?
    }, $seeded_slug)->hash->{platform_pricing_plan_id};

    my $platform_plan = $db->query(q{
        SELECT id, pricing_configuration
          FROM registry.pricing_plans
         WHERE plan_scope = 'platform'
           AND metadata->>'default' = 'true'
         LIMIT 1
    })->hash;

    $db->query(q{
        UPDATE registry.tenants SET platform_pricing_plan_id = NULL WHERE slug = ?
    }, $seeded_slug);

    $db->query(q{
        UPDATE registry.pricing_plans
           SET pricing_configuration = pricing_configuration
                   || '{"refund_application_fee": false}'::jsonb
         WHERE id = ?
    }, $platform_plan->{id});

    my $flag = refund_application_fee_for_tenant($db, $seeded_slug);
    is $flag, 0, 'NULL FK + platform default plan sets false -> 0';

    # Restore: platform plan first, then tenant FK
    $db->query(q{
        UPDATE registry.pricing_plans SET pricing_configuration = ? WHERE id = ?
    }, $platform_plan->{pricing_configuration}, $platform_plan->{id});

    $db->query(q{
        UPDATE registry.tenants SET platform_pricing_plan_id = ? WHERE slug = ?
    }, $saved_fk, $seeded_slug);
};

subtest 'malformed refund_application_fee value dies with informative message' => sub {
    my $plan_id = $db->query(q{
        SELECT platform_pricing_plan_id FROM registry.tenants WHERE slug = ?
    }, $seeded_slug)->hash->{platform_pricing_plan_id};

    my $saved = $db->query(q{
        SELECT pricing_configuration FROM registry.pricing_plans WHERE id = ?
    }, $plan_id)->hash;

    $db->query(q{
        UPDATE registry.pricing_plans
           SET pricing_configuration = pricing_configuration
                   || '{"refund_application_fee": "sometimes"}'::jsonb
         WHERE id = ?
    }, $plan_id);

    my $result = eval { refund_application_fee_for_tenant($db, $seeded_slug) };
    like $@, qr/refund_application_fee/,
        'malformed value dies with message mentioning refund_application_fee';

    $db->query(q{
        UPDATE registry.pricing_plans SET pricing_configuration = ? WHERE id = ?
    }, $saved->{pricing_configuration}, $plan_id);
};

subtest 'missing platform default plan with NULL FK causes die (A1)' => sub {
    my $saved_fk = $db->query(q{
        SELECT platform_pricing_plan_id FROM registry.tenants WHERE slug = ?
    }, $seeded_slug)->hash->{platform_pricing_plan_id};

    my $free_plan = $db->query(q{
        SELECT id, plan_scope, plan_name, plan_type, pricing_model_type,
               amount_cents, currency, installments_allowed, requirements,
               pricing_configuration, metadata
          FROM registry.pricing_plans
         WHERE plan_scope = 'platform'
           AND metadata->>'default' = 'true'
         LIMIT 1
    })->hash;

    # Null FK before deleting (FK constraint)
    $db->query(q{
        UPDATE registry.tenants SET platform_pricing_plan_id = NULL WHERE slug = ?
    }, $seeded_slug);

    $db->query(q{
        DELETE FROM registry.pricing_plans WHERE id = ?
    }, $free_plan->{id});

    my $result = eval { refund_application_fee_for_tenant($db, $seeded_slug) };
    like $@, qr/Free|fallback|platform|default/i,
        'dies with informative message when platform default plan is absent';

    # Restore: re-insert plan, then restore FK
    $db->query(q{
        INSERT INTO registry.pricing_plans
            (id, plan_scope, plan_name, plan_type, pricing_model_type,
             amount_cents, currency, installments_allowed, requirements,
             pricing_configuration, metadata)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?::jsonb, ?::jsonb, ?::jsonb)
    }, $free_plan->{id}, $free_plan->{plan_scope}, $free_plan->{plan_name},
       $free_plan->{plan_type}, $free_plan->{pricing_model_type},
       $free_plan->{amount_cents}, $free_plan->{currency},
       $free_plan->{installments_allowed}, $free_plan->{requirements},
       $free_plan->{pricing_configuration}, $free_plan->{metadata});

    $db->query(q{
        UPDATE registry.tenants SET platform_pricing_plan_id = ? WHERE slug = ?
    }, $saved_fk, $seeded_slug);
};

# --- A2: Payment->refund and refund_async send Connect params for tenant payments ---

use Registry::DAO::Payment;
use Mojo::Promise;
use Registry::Service::Stripe;  # load package before glob replacement

# The seeded_slug ('registry') is excluded by _refund_connect_params' gate
# (slug ne 'registry'). Create a separate test tenant with a non-registry slug
# linked to the same plan so we can exercise the Connect-param path.
my $a2_plan_id = $db->query(q{
    SELECT platform_pricing_plan_id FROM registry.tenants WHERE slug = ?
}, $seeded_slug)->hash->{platform_pricing_plan_id};

my $a2_slug = 'a2test_tenant';
$db->query(q{
    INSERT INTO registry.tenants (name, slug, platform_pricing_plan_id)
    VALUES ('A2 Test Tenant', ?, ?)
    ON CONFLICT (slug) DO UPDATE SET platform_pricing_plan_id = EXCLUDED.platform_pricing_plan_id
}, $a2_slug, $a2_plan_id);

ok $a2_plan_id, "resolved plan_id for A2 subtests (slug=$a2_slug)";

# A minimal user satisfies the NOT NULL FK on registry.payments.user_id.
# Raw insert avoids Crypt::Passphrase overhead for a throwaway fixture.
my $test_user_id = $db->query(q{
    INSERT INTO registry.users (username, passhash)
    VALUES ('a2_refund_test', 'nohash')
    RETURNING id
})->hash->{id};

ok $test_user_id, "created test user for A2 Payment->refund subtests";

subtest 'tenant refund honors plan opt-out (refund_application_fee=false)' => sub {
    my $saved = $db->query(q{
        SELECT pricing_configuration FROM registry.pricing_plans WHERE id = ?
    }, $a2_plan_id)->hash;

    $db->query(q{
        UPDATE registry.pricing_plans
           SET pricing_configuration = pricing_configuration
                   || '{"refund_application_fee": false}'::jsonb
         WHERE id = ?
    }, $a2_plan_id);

    my $payment = Registry::DAO::Payment->create($db, {
        user_id                  => $test_user_id,
        amount_cents             => 10000,
        status                   => 'completed',
        stripe_payment_intent_id => 'pi_tenant_optout',
        metadata                 => { tenant_slug => $a2_slug },
    });

    my %captured;
    {
        no warnings 'redefine';
        local $ENV{STRIPE_SECRET_KEY} = 'sk_test_fake_for_refund_tests';
        local *Registry::Service::Stripe::create_refund = sub ($s, $p) {
            %captured = %$p;
            return { id => 're_optout_fake' };
        };
        $payment->refund($db);
    }

    is $captured{reverse_transfer},       'true',  'tenant refund sets reverse_transfer=true (string)';
    is $captured{refund_application_fee}, 'false', 'tenant refund honors plan opt-out (false string)';
    ok exists $captured{payment_intent},           'payment_intent still present';

    # Finding 3: verify save() actually persisted the refund state to the DB row.
    my $row  = $db->select('payments', '*', { id => $payment->id })->hash;
    is $row->{status}, 'refunded', 'save() persisted status=refunded';
    my $saved_meta = ref $row->{metadata} ? $row->{metadata} : decode_json($row->{metadata} // '{}');
    is  $saved_meta->{refund_id},          're_optout_fake', 'save() persisted refund_id in metadata';
    cmp_ok $saved_meta->{refund_amount_cents}, q{==}, 10000, q{save() persisted refund_amount_cents in metadata};

    $db->query(q{
        UPDATE registry.pricing_plans SET pricing_configuration = ? WHERE id = ?
    }, $saved->{pricing_configuration}, $a2_plan_id);
};

subtest 'tenant refund with absent refund_application_fee key defaults to 1' => sub {
    my $saved = $db->query(q{
        SELECT pricing_configuration FROM registry.pricing_plans WHERE id = ?
    }, $a2_plan_id)->hash;

    # Remove the key so the absent-key default path is exercised
    $db->query(q{
        UPDATE registry.pricing_plans
           SET pricing_configuration = pricing_configuration - 'refund_application_fee'
         WHERE id = ?
    }, $a2_plan_id);

    my $payment = Registry::DAO::Payment->create($db, {
        user_id                  => $test_user_id,
        amount_cents             => 10000,
        status                   => 'completed',
        stripe_payment_intent_id => 'pi_tenant_default',
        metadata                 => { tenant_slug => $a2_slug },
    });

    my %captured;
    {
        no warnings 'redefine';
        local $ENV{STRIPE_SECRET_KEY} = 'sk_test_fake_for_refund_tests';
        local *Registry::Service::Stripe::create_refund = sub ($s, $p) {
            %captured = %$p;
            return { id => 're_default_fake' };
        };
        $payment->refund($db);
    }

    is $captured{reverse_transfer},       'true', 'tenant refund sets reverse_transfer=true (string)';
    is $captured{refund_application_fee}, 'true', 'absent key -> default refund_application_fee=true (string)';

    $db->query(q{
        UPDATE registry.pricing_plans SET pricing_configuration = ? WHERE id = ?
    }, $saved->{pricing_configuration}, $a2_plan_id);
};

subtest 'registry (non-tenant) payment refund sends no Connect params' => sub {
    my $payment = Registry::DAO::Payment->create($db, {
        user_id                  => $test_user_id,
        amount_cents             => 5000,
        status                   => 'completed',
        stripe_payment_intent_id => 'pi_registry_only',
        metadata                 => {},
    });

    my %captured;
    {
        no warnings 'redefine';
        local $ENV{STRIPE_SECRET_KEY} = 'sk_test_fake_for_refund_tests';
        local *Registry::Service::Stripe::create_refund = sub ($s, $p) {
            %captured = %$p;
            return { id => 're_registry_fake' };
        };
        $payment->refund($db);
    }

    ok !exists $captured{reverse_transfer},       'registry refund: no reverse_transfer';
    ok !exists $captured{refund_application_fee}, 'registry refund: no refund_application_fee';
    ok  exists $captured{payment_intent},         'registry refund: payment_intent present';
    ok  exists $captured{amount},                 'registry refund: amount present';
    ok  exists $captured{reason},                 'registry refund: reason present';
};

# Finding 2: pin the `$slug ne 'registry'` gate. tenant_slug='registry' must
# also produce no Connect params, distinct from the no-slug case above.
subtest 'tenant_slug=registry is treated as platform payment (no Connect params)' => sub {
    my $payment = Registry::DAO::Payment->create($db, {
        user_id                  => $test_user_id,
        amount_cents             => 7500,
        status                   => 'completed',
        stripe_payment_intent_id => 'pi_registry_slug_gate',
        metadata                 => { tenant_slug => 'registry' },
    });

    my %captured;
    {
        no warnings 'redefine';
        local $ENV{STRIPE_SECRET_KEY} = 'sk_test_fake_for_refund_tests';
        local *Registry::Service::Stripe::create_refund = sub ($s, $p) {
            %captured = %$p;
            return { id => 're_registry_gate_fake' };
        };
        $payment->refund($db);
    }

    ok !exists $captured{reverse_transfer},       'registry-slug gate: no reverse_transfer';
    ok !exists $captured{refund_application_fee}, 'registry-slug gate: no refund_application_fee';
    ok  exists $captured{payment_intent},         'registry-slug gate: payment_intent present';
};

subtest 'refund_async sends the same Connect params as refund (sync)' => sub {
    my $saved = $db->query(q{
        SELECT pricing_configuration FROM registry.pricing_plans WHERE id = ?
    }, $a2_plan_id)->hash;

    $db->query(q{
        UPDATE registry.pricing_plans
           SET pricing_configuration = pricing_configuration - 'refund_application_fee'
         WHERE id = ?
    }, $a2_plan_id);

    my $payment = Registry::DAO::Payment->create($db, {
        user_id                  => $test_user_id,
        amount_cents             => 10000,
        status                   => 'completed',
        stripe_payment_intent_id => 'pi_async_tenant',
        metadata                 => { tenant_slug => $a2_slug },
    });

    my %captured;
    my ($async_result, $async_err);
    {
        no warnings 'redefine';
        local $ENV{STRIPE_SECRET_KEY} = 'sk_test_fake_for_refund_tests';
        local *Registry::Service::Stripe::create_refund_async = sub ($s, $p) {
            %captured = %$p;
            return Mojo::Promise->resolve({ id => 're_async_fake' });
        };
        $payment->refund_async($db)
            ->then(sub { $async_result = shift })
            ->catch(sub { $async_err = shift })
            ->wait;
    }

    is $async_err,    undef,          'refund_async: promise did not reject';
    is $async_result->{id}, 're_async_fake', 'refund_async: resolved with refund object';
    is $captured{reverse_transfer},       'true', 'refund_async: tenant sets reverse_transfer=true (string)';
    is $captured{refund_application_fee}, 'true', 'refund_async: absent key -> refund_application_fee=true (string)';
    ok  exists $captured{payment_intent},         'refund_async: payment_intent present';

    $db->query(q{
        UPDATE registry.pricing_plans SET pricing_configuration = ? WHERE id = ?
    }, $saved->{pricing_configuration}, $a2_plan_id);
};

done_testing;
