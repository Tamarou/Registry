#!/usr/bin/env perl
# ABOUTME: Tenant slugs are lowercase, because every routing path already assumes it.
# ABOUTME: A mixed-case slug broke clone_schema partway and was unreachable besides.

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO;
use Registry::DAO::Tenant;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

sub schema_exists ($name) {
    return !!$db->query(
        'SELECT 1 FROM information_schema.schemata WHERE schema_name = ?', $name )->array;
}

# clone_schema does PERFORM set_config('search_path', dest_schema, true) on the
# UNQUOTED name, which case-folds -- so a mixed-case slug dies partway through
# and leaves a half-built schema. Nothing prevented a tenant signing up with one:
# provision lowercased only when it DERIVED the slug from the name, never when
# one was supplied.
subtest 'a supplied mixed-case slug is normalised before it reaches clone_schema' => sub {
    my $tenant = Registry::DAO::Tenant->provision( $db,
        { name => 'Super Awesome Cool', slug => 'SuperAwesomeCool', users => [] } );

    ok $tenant, 'provisioning succeeds';
    is $tenant->slug, 'superawesomecool', 'the stored slug is lowercase';
    ok schema_exists('superawesomecool'), 'and its schema is there';
    ok !schema_exists('SuperAwesomeCool'), 'with no mixed-case schema beside it';
};

subtest 'hyphens still become underscores' => sub {
    my $tenant = Registry::DAO::Tenant->provision( $db,
        { name => 'Hyphen Co', slug => 'Hyphen-Co', users => [] } );

    is $tenant->slug, 'hyphen_co', 'lowercased and hyphens replaced';
    ok schema_exists('hyphen_co'), 'and the schema matches the stored slug';
};

# Every routing path already assumes lowercase: _extract_tenant_from_subdomain
# lowercases the Host header, and the tenant helper's own regex is
# /\A[a-z][a-z0-9_]{0,62}\z/. A mixed-case tenant could never have been reached
# even if clone_schema had managed to build it.
# The regression the e2e suite caught. create must NOT rewrite a supplied slug:
# t/playwright/setup_registration_test_data.pl searches for a hyphenated slug and
# creates with the same string, so normalising inside create meant find could
# never match its own row and the second run inserted a duplicate.
subtest 'create leaves a supplied slug alone, so find-then-create stays idempotent' => sub {
    my $slug = 'seed-style-slug';

    my $first = Registry::DAO::Tenant->find( $db, { slug => $slug } )
      || Registry::DAO::Tenant->create( $db, { name => 'Seed Style', slug => $slug } );
    is $first->slug, $slug, 'the slug is stored exactly as supplied';

    my $second = Registry::DAO::Tenant->find( $db, { slug => $slug } )
      || Registry::DAO::Tenant->create( $db, { name => 'Seed Style', slug => $slug } );
    is $second->id, $first->id, 'the second pass finds the row rather than duplicating it';
};

subtest 'the database refuses a mixed-case slug outright' => sub {
    my $err;
    eval {
        $db->query( "INSERT INTO registry.tenants (name, slug) VALUES (?, ?)",
            'Direct Insert', 'MixedCase' );
        1;
    } or $err = $@;

    ok $err, 'the insert is rejected' or return;
    like $err, qr/slug|check/i, 'by a constraint on slug';
};

subtest 'a lowercase slug inserts normally' => sub {
    my $ok = eval {
        $db->query( "INSERT INTO registry.tenants (name, slug) VALUES (?, ?)",
            'Fine Insert', 'fine_slug' );
        1;
    };
    ok $ok, 'the constraint does not reject a well-formed slug' or diag $@;
};

done_testing;
