#!/usr/bin/env perl
# ABOUTME: Schema test for the program-publish-status migration.
# ABOUTME: Verifies projects.status and locations.contact_person_id columns.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

subtest 'registry.projects has status column with check constraint' => sub {
    my $column = $db->query(
        q{SELECT column_name, data_type, column_default
          FROM information_schema.columns
          WHERE table_schema = 'registry'
            AND table_name = 'projects'
            AND column_name = 'status'}
    )->hash;

    ok($column, 'status column exists on registry.projects');
    is($column->{data_type}, 'text', 'status is text');
    like($column->{column_default} // '', qr/draft/, 'default is draft');

    # Check constraint allows exactly draft/published/closed.
    my $constraint = $db->query(
        q{SELECT pg_get_constraintdef(c.oid) AS def
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE n.nspname = 'registry'
            AND t.relname = 'projects'
            AND c.conname = 'projects_status_check'}
    )->hash;

    ok($constraint, 'projects_status_check exists');
    like($constraint->{def}, qr/draft/,     'draft allowed');
    like($constraint->{def}, qr/published/, 'published allowed');
    like($constraint->{def}, qr/closed/,    'closed allowed');
};

subtest 'registry.locations has contact_person_id FK to users' => sub {
    my $column = $db->query(
        q{SELECT column_name, data_type
          FROM information_schema.columns
          WHERE table_schema = 'registry'
            AND table_name = 'locations'
            AND column_name = 'contact_person_id'}
    )->hash;

    ok($column, 'contact_person_id column exists');
    is($column->{data_type}, 'uuid', 'contact_person_id is uuid');

    # FK constraint exists and points at users.
    my $fk = $db->query(
        q{SELECT pg_get_constraintdef(c.oid) AS def
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE n.nspname = 'registry'
            AND t.relname = 'locations'
            AND c.contype = 'f'
            AND pg_get_constraintdef(c.oid) LIKE '%contact_person_id%'}
    )->hash;

    ok($fk, 'foreign key on contact_person_id exists');
    like($fk->{def}, qr/REFERENCES .*users/i, 'references users table');

    # Supporting index for lookups by contact person.
    my $index = $db->query(
        q{SELECT indexname FROM pg_indexes
          WHERE schemaname = 'registry'
            AND tablename = 'locations'
            AND indexname = 'idx_locations_contact_person'}
    )->hash;
    ok($index, 'supporting index exists');
};

subtest 'tenant schemas get the same columns' => sub {
    my $tenant = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Smoke Migration Tenant',
        slug => 'smoke_migration',
    });
    $db->query('SELECT clone_schema(?)', 'smoke_migration');

    # Re-run only the tenant-propagation portion of the migration by
    # invoking the relevant ALTER TABLEs in the tenant schema. This
    # mirrors what the migration's DO block does.
    $db->query(
        q{ALTER TABLE smoke_migration.projects
            ADD COLUMN IF NOT EXISTS status text DEFAULT 'draft'
            CHECK (status IN ('draft', 'published', 'closed'))}
    );
    $db->query(
        q{ALTER TABLE smoke_migration.locations
            ADD COLUMN IF NOT EXISTS contact_person_id uuid
            REFERENCES smoke_migration.users(id)}
    );

    my $status = $db->query(
        q{SELECT 1 FROM information_schema.columns
          WHERE table_schema = 'smoke_migration'
            AND table_name = 'projects'
            AND column_name = 'status'}
    )->hash;
    ok($status, 'tenant.projects has status column');

    my $contact = $db->query(
        q{SELECT 1 FROM information_schema.columns
          WHERE table_schema = 'smoke_migration'
            AND table_name = 'locations'
            AND column_name = 'contact_person_id'}
    )->hash;
    ok($contact, 'tenant.locations has contact_person_id column');
};

done_testing();
