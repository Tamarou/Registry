#!/usr/bin/env perl
# ABOUTME: The operator right is held by a tenant as seeded data and read through one seam.
# ABOUTME: The job queue and the cross-tenant revenue view are served only to admins of its holder.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( authenticate_as );
use Registry::DAO::Tenant;
use Registry::DAO::User;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $platform = Registry::DAO::Tenant->platform($db);

my $studio = Test::Registry::Fixtures::create_tenant( $db, {
    name => 'Operator Right Studio', slug => 'operator_right_studio',
} );

subtest 'the platform tenant holds the operator right and other tenants do not' => sub {
    ok Registry::DAO::Tenant->holds( $db, $platform->id, 'operator' ),
        'the platform tenant holds operator, as the deploy migration seeded it';
    ok !Registry::DAO::Tenant->holds( $db, $studio->id, 'operator' ),
        'a provisioned tenant does not';
};

done_testing;
