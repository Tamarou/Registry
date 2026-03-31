#!/usr/bin/env perl
# ABOUTME: Tests for Tenant DAO update_canonical_domain method.
# ABOUTME: Verifies setting, updating, and clearing the canonical_domain field.
use 5.42.0;
use warnings;
use utf8;

use Test::More;

use lib qw(lib t/lib);
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry::DAO::Tenant;

my $t  = Test::Registry::DB->new;
my $db = $t->db;

subtest 'update_canonical_domain sets the canonical domain' => sub {
    my $tenant = Test::Registry::Fixtures::create_tenant( $db, {
        name => 'Domain Tenant',
        slug => 'domain_tenant',
    } );

    $tenant->update_canonical_domain( $db->db, 'example.com' );

    my $reloaded = Registry::DAO::Tenant->find( $db->db, { id => $tenant->id } );
    is( $reloaded->canonical_domain, 'example.com',
        'canonical_domain updated correctly' );

    # Clear it again
    $tenant->update_canonical_domain( $db->db, undef );
    $reloaded = Registry::DAO::Tenant->find( $db->db, { id => $tenant->id } );
    is( $reloaded->canonical_domain, undef, 'canonical_domain cleared correctly' );
};

done_testing();
