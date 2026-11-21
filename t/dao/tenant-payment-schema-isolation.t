#!/usr/bin/env perl
# ABOUTME: Tests that each tenant schema has its own payment tables with tenant-local FKs.
# ABOUTME: Structural invariant tests, migration move/guard logic, and the #237 behavioral repro.
use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw(done_testing is ok subtest note like)];
defer { done_testing };

use Test::Registry::DB;
use Mojo::Home;
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Payment;

my $t   = Test::Registry::DB->new;
my $dao = $t->db;
my $db  = $dao->db;

# Provision a fresh tenant so we can assert on its schema shape.
my $slug  = 'pay_iso_test_' . $$;
my $admin = Registry::DAO::User->create($db, {
    username  => "pay_iso_admin_$$",
    email     => "pay_iso_admin_$$\@test.example",
    name      => 'PayIso Admin',
    user_type => 'admin',
});

my $tenant = Registry::DAO::Tenant->provision($db, {
    name  => "PayIso Test $$",
    slug  => $slug,
    users => [ $admin ],
});
ok $tenant, 'tenant provisioned';

# ---- structural assertions --------------------------------------------------
# These must be green both before AND after the migration is written because
# clone_schema copies all registry tables (including payments/payment_items/
# payment_schedules/scheduled_payments) at provisioning time.

subtest 'payment tables exist in tenant schema' => sub {
    for my $tbl (qw(payments payment_items payment_schedules scheduled_payments)) {
        my ($row) = $db->select('information_schema.tables', ['table_name'], {
            table_schema => $slug,
            table_name   => $tbl,
        })->hashes->each;
        ok $row, "tenant schema has table '$tbl'";
    }
};

subtest 'enrollments.payment_id FK references tenant payments table' => sub {
    # Query pg_constraint to find the FK on enrollments(payment_id) in the
    # tenant schema and verify it references the tenant's own payments table
    # (not registry.payments).
    my $row = $db->query(q{
        SELECT
            con.conname,
            ref_ns.nspname  AS ref_schema,
            ref_cl.relname  AS ref_table
        FROM pg_constraint con
        JOIN pg_class      src_cl  ON src_cl.oid  = con.conrelid
        JOIN pg_namespace  src_ns  ON src_ns.oid  = src_cl.relnamespace
        JOIN pg_attribute  att     ON att.attrelid = con.conrelid
                                  AND att.attnum   = ANY(con.conkey)
        JOIN pg_class      ref_cl  ON ref_cl.oid  = con.confrelid
        JOIN pg_namespace  ref_ns  ON ref_ns.oid  = ref_cl.relnamespace
        WHERE con.contype    = 'f'
          AND src_ns.nspname = $1
          AND src_cl.relname = 'enrollments'
          AND att.attname    = 'payment_id'
    }, $slug)->hash;

    ok $row, 'found enrollments.payment_id FK in tenant schema';
    is $row->{ref_schema}, $slug,      'FK references tenant schema (not registry)';
    is $row->{ref_table},  'payments', 'FK references payments table';
};

# Create a parent directly in the tenant schema so their user row does NOT
# exist in registry.users.  copy_user preserves ids, so a provision-copied
# user would satisfy a registry-side FK and mask a schema-isolation bug.
my $tenant_dao = Registry::DAO->new(url => $ENV{DB_URL}, schema => $slug);
my $tenant_db  = $tenant_dao->db;

my $parent = Registry::DAO::User->create($tenant_db, {
    username  => "pay_iso_parent_$$",
    email     => "pay_iso_parent_$$\@test.example",
    name      => 'PayIso Parent',
    user_type => 'parent',
});
ok $parent, 'parent user created only in tenant schema';

# ---- migration move-logic tests ---------------------------------------------
# These subtests exercise the deploy script's row-move path by reading the DO
# block out of sql/deploy/tenant-scoped-payments.sql and re-executing it
# against the test DB.  The deploy script is idempotent by design, so re-
# running it here is safe: table-creation steps skip (to_regclass guards),
# and the move INSERTs are guarded by "NOT EXISTS" conditions inherent in the
# fact that the rows only exist in registry.payments until moved.
#
# The $admin user was provisioned via Tenant->provision, which calls copy_user,
# so $admin is dual-resident (exists in both registry.users and $slug.users).
# This satisfies the payer pre-flight and lets the row-move INSERT into
# <tenant>.payments pass its user_id FK.

# Extract the raw DO block from the deploy script so we can run it directly.
my $deploy_sql_path = Mojo::Home->new->child('sql/deploy/tenant-scoped-payments.sql');
my $deploy_sql      = $deploy_sql_path->slurp;

# Strip the sqitch header (BEGIN/COMMIT wrapper); keep only the DO block.
# The file structure is: preamble SET lines, then DO $$ ... $$ LANGUAGE plpgsql;
# Anchor on DO at the start of a line so a "do" inside the comment preamble
# can never be mistaken for the block opener.
( my $do_block = $deploy_sql ) =~ s{\A.*?^(DO\b)}{$1}ms;
$do_block =~ s/\s*COMMIT;\s*\z//s;

subtest 'migration move-logic: rows land in tenant schema' => sub {
    # Insert a registry.payments row attributed to our test tenant.
    # $admin->id is dual-resident (exists in both registry.users and
    # $slug.users via copy_user at provisioning), so the payer pre-flight passes.
    my $pay_id = $db->query(
        q{INSERT INTO registry.payments
              (user_id, amount, currency, status, metadata)
          VALUES ($1, 75.00, 'USD', 'pending',
                  jsonb_build_object('tenant_slug', $2::text))
          RETURNING id},
        $admin->id, $slug
    )->hash->{id};
    ok $pay_id, 'seeded registry.payments row for tenant';

    # Insert a linked payment_items row.
    my $item_id = $db->query(
        q{INSERT INTO registry.payment_items
              (payment_id, description, amount, quantity, metadata)
          VALUES ($1, 'Test item', 75.00, 1, '{}')
          RETURNING id},
        $pay_id
    )->hash->{id};
    ok $item_id, 'seeded registry.payment_items row';

    # Re-run the deploy DO block -- should move both rows.
    $db->query($do_block);

    # Row must now be in the tenant schema.  Use $tenant_db (search_path = $slug)
    # so the unqualified table name resolves to the tenant schema.
    my $in_tenant = $tenant_db->select('payments', ['id'], { id => $pay_id })->hash;
    ok $in_tenant, 'payment row found in tenant schema after migration move';

    # Row must no longer be in registry.
    my $in_registry = $db->select('registry.payments', ['id'], { id => $pay_id })->hash;
    ok !$in_registry, 'payment row removed from registry.payments after migration move';

    # payment_items row must be in the tenant schema.
    my $item_in_tenant = $tenant_db->select('payment_items', ['id'], { id => $item_id })->hash;
    ok $item_in_tenant, 'payment_items row found in tenant schema after migration move';

    # payment_items row must no longer be in registry.
    my $item_in_registry = $db->select('registry.payment_items', ['id'], { id => $item_id })->hash;
    ok !$item_in_registry, 'payment_items row removed from registry.payment_items after migration move';
};

subtest 'migration schedule-guard: blocks move when scheduled_payments reference target' => sub {
    # Seed a fresh registry.payments row for this tenant.
    my $pay_id2 = $db->query(
        q{INSERT INTO registry.payments
              (user_id, amount, currency, status, metadata)
          VALUES ($1, 100.00, 'USD', 'pending',
                  jsonb_build_object('tenant_slug', $2::text))
          RETURNING id},
        $admin->id, $slug
    )->hash->{id};
    ok $pay_id2, 'seeded registry.payments row for guard test';

    # Seed a payment_schedules row.  enrollment_id and pricing_plan_id are
    # plain UUID NOT NULL columns with no FK -- gen_random_uuid() is sufficient.
    my $sched_id = $db->query(
        q{INSERT INTO registry.payment_schedules
              (enrollment_id, pricing_plan_id, total_amount,
               installment_amount, installment_count)
          VALUES (gen_random_uuid(), gen_random_uuid(), 100.00, 50.00, 2)
          RETURNING id}
    )->hash->{id};
    ok $sched_id, 'seeded registry.payment_schedules row';

    # Seed a scheduled_payments row linking the schedule to the to-move payment.
    my $sp_id = $db->query(
        q{INSERT INTO registry.scheduled_payments
              (payment_schedule_id, payment_id, installment_number, amount)
          VALUES ($1, $2, 1, 50.00)
          RETURNING id},
        $sched_id, $pay_id2
    )->hash->{id};
    ok $sp_id, 'seeded registry.scheduled_payments row referencing to-move payment';

    # Re-running the deploy DO block should now raise the schedule guard.
    eval { $db->query($do_block) };
    my $guard_err = $@ // '';
    ok $guard_err, 'deploy DO block raised exception when scheduled_payments guard fires';
    like $guard_err, qr/pre-flight FAILED/, 'exception message matches schedule guard pattern';

    # Clean up the blocking rows.
    $db->query('DELETE FROM registry.scheduled_payments WHERE id = $1', $sp_id);
    $db->query('DELETE FROM registry.payment_schedules WHERE id = $1', $sched_id);

    # After removing the schedule blocker the DO block should succeed.
    eval { $db->query($do_block) };
    my $after_err = $@ // '';
    ok !$after_err, 'deploy DO block succeeds after schedule rows removed'
        or note "Unexpected error: $after_err";

    # Confirm the payment row moved to the tenant schema.
    my $in_tenant = $tenant_db->select('payments', ['id'], { id => $pay_id2 })->hash;
    ok $in_tenant, 'payment row moved to tenant schema after guard cleared';
};

# ---- behavioral block (#237 repro) ------------------------------------------
# Payment DAO uses unqualified table names so inserts resolve via the tenant
# search_path.  A parent that lives only in the tenant schema satisfies the
# tenant FK (not registry.users), and the payment lands in the tenant schema.

my $payment = Registry::DAO::Payment->create($tenant_db, {
    user_id => $parent->id,
    amount  => '50.00',
});
ok $payment, 'payment created successfully in tenant schema';

# Verify the row landed in the tenant schema, NOT registry.payments.
my $in_tenant = $tenant_db->select(
    'payments', ['id'], { id => $payment->id }
)->hash;
ok $in_tenant, 'payment row found in tenant schema';

my $in_registry = $db->select(
    'registry.payments', ['id'], { id => $payment->id }
)->hash;
ok !$in_registry, 'payment row NOT in registry.payments';
