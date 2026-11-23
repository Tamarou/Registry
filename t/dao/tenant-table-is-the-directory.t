#!/usr/bin/env perl
# ABOUTME: Registry::DAO::Tenant reads and writes registry.tenants on any connection, the platform's directory.
# ABOUTME: clone_schema gives each tenant schema an empty tenants copy that a tenant connection must never use.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;

use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO;
use Registry::DAO::Tenant;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

my $PLATFORM_ID = '00000000-0000-0000-0000-000000000000';

my $tenant = Test::Registry::Fixtures::create_tenant( $dao->db,
    { name => 'Directory Studio', slug => 'directory_studio' } );
my $tenant_db = $dao->connect_schema('directory_studio')->db;

sub own_copy_count ( $schema ) {
    return $dao->db->query( qq{SELECT count(*) AS n FROM "$schema".tenants} )->hash->{n};
}

subtest 'find on a tenant connection reads the directory' => sub {
    my $platform = Registry::DAO::Tenant->find( $tenant_db, { slug => 'registry' } );
    ok $platform, 'the platform row is found';
    is $platform && $platform->id, $PLATFORM_ID, 'and it is the all-zeros directory row';

    my $own = Registry::DAO::Tenant->find( $tenant_db, { slug => 'directory_studio' } );
    is $own && $own->id, $tenant->id, "the tenant's own row is found too";
};

subtest 'update on a tenant connection writes the directory' => sub {
    $tenant->update( $tenant_db, { canonical_domain => 'directory.example.com' } );

    my $row = $dao->db->query( 'SELECT canonical_domain FROM registry.tenants WHERE id = ?', $tenant->id )->hash;
    is $row->{canonical_domain}, 'directory.example.com', 'registry.tenants holds the change';
};

subtest 'a row in the tenant own tenants copy cannot shadow the directory' => sub {
    $dao->db->query(
        q{INSERT INTO directory_studio.tenants (id, name, slug) VALUES (gen_random_uuid(), 'Impostor', 'registry')} );

    my $platform = Registry::DAO::Tenant->find( $tenant_db, { slug => 'registry' } );
    is $platform && $platform->id, $PLATFORM_ID, 'the directory row wins over the planted copy';

    $dao->db->query(q{DELETE FROM directory_studio.tenants});
};

subtest 'create on a tenant connection writes the directory only' => sub {
    my $made = Registry::DAO::Tenant->create( $tenant_db, { name => 'Made Here', slug => 'made_here' } );

    ok $dao->db->query( 'SELECT 1 FROM registry.tenants WHERE id = ?', $made->id )->array,
        'the new tenant is a registry.tenants row';
    is own_copy_count('directory_studio'), 0, "the tenant schema's own copy stays empty";
};

subtest 'an unknown slug on a tenant connection returns undef' => sub {
    my $found = eval { Registry::DAO::Tenant->find( $tenant_db, { slug => 'nowhere_at_all' } ) };
    is $@, '', 'the lookup does not die';
    is $found, undef, 'and finds nothing';
};

# A hyphenated slug is no longer creatable (normalize_slug), and clone_schema
# cannot build one, so this schema is made by hand: the point is only that a
# connection whose search_path names a quoted schema still uses the directory.
subtest 'a hyphenated tenant reads and writes the directory' => sub {
    $dao->db->query(
        q{INSERT INTO registry.tenants (name, slug) VALUES ('Hyphen Studio', 'hyphen-studio')} );
    $dao->db->query(q{CREATE SCHEMA "hyphen-studio"});
    $dao->db->query(q{CREATE TABLE "hyphen-studio".tenants (LIKE registry.tenants INCLUDING ALL)});
    my $hy_db = $dao->connect_schema('hyphen-studio')->db;

    my $own = Registry::DAO::Tenant->find( $hy_db, { slug => 'hyphen-studio' } );
    ok $own, 'its own row is found in the directory';

    my $platform = Registry::DAO::Tenant->find( $hy_db, { slug => 'registry' } );
    is $platform && $platform->id, $PLATFORM_ID, 'the platform row is the directory row';

    $own->update( $hy_db, { canonical_domain => 'hyphen.example.com' } ) if $own;
    my $row = $dao->db->query( q{SELECT canonical_domain FROM registry.tenants WHERE slug = 'hyphen-studio'} )->hash;
    is $row->{canonical_domain}, 'hyphen.example.com', 'an update lands in registry.tenants';
    is own_copy_count('hyphen-studio'), 0, "the hyphenated schema's own copy stays empty";
};

done_testing;
