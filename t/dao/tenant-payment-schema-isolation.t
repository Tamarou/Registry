#!/usr/bin/env perl
# ABOUTME: Tests that each tenant schema has its own payment tables with tenant-local FKs.
# ABOUTME: Structural invariant tests and the #237 behavioral repro.
use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw(done_testing is ok subtest)];
defer { done_testing };

use Test::Registry::DB;
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
# clone_schema copies all registry tables (including payments and
# payment_items) at provisioning time.

subtest 'payment tables exist in tenant schema' => sub {
    for my $tbl (qw(payments payment_items)) {
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

# ---- behavioral block (#237 repro) ------------------------------------------
# Payment DAO uses unqualified table names so inserts resolve via the tenant
# search_path.  A parent that lives only in the tenant schema satisfies the
# tenant FK (not registry.users), and the payment lands in the tenant schema.

my $payment = Registry::DAO::Payment->create($tenant_db, {
    user_id => $parent->id,
    amount_cents => 5000,
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
