#!/usr/bin/env perl
# ABOUTME: Deployment configuration writes Tamarou's Stripe account and readiness onto the registry row.
# ABOUTME: Without it the platform reads as not connected and the connect action would mint a second account.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;

use Test::Registry::DB;
use Registry::DAO::Tenant;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# A second tenant, so "only the registry row changes" has something to be
# wrong about.
Registry::DAO::Tenant->create( $dao->db, { name => 'Bystander Studio', slug => 'bystander' } );

sub tenant_rows ($db) {
    return $db->query('SELECT * FROM registry.tenants ORDER BY id')->hashes->to_array;
}

sub other_tenant_rows ($db) {
    return [ grep { $_->{slug} ne 'registry' } tenant_rows($db)->@* ];
}

sub platform_row ($db) {
    return $db->query(q{SELECT * FROM registry.tenants WHERE slug = 'registry'})->hash;
}

sub reset_platform ($db) {
    $db->query(q{
        UPDATE registry.tenants SET stripe_connect_account_id = NULL,
            stripe_charges_enabled = FALSE, stripe_details_submitted = FALSE
        WHERE slug = 'registry'
    });
}

subtest 'bootstrap writes the configured stripe account onto the registry row' => sub {
    my $db = $dao->db;
    reset_platform($db);
    my $others_before = other_tenant_rows($db);

    Registry::DAO::Tenant->bootstrap_platform( $db, {
        PLATFORM_STRIPE_ACCOUNT_ID => 'acct_test_platform',
        PLATFORM_STRIPE_READY      => 1,
    } );

    my $row = platform_row($db);
    is $row->{stripe_connect_account_id}, 'acct_test_platform',
        'the registry row names the configured account';
    ok $row->{stripe_charges_enabled},   'charges are enabled';
    ok $row->{stripe_details_submitted}, 'details are submitted';
    ok Registry::DAO::Tenant->platform($db)->stripe_connect_ready,
        'so the platform tenant reads as connect-ready';

    is_deeply other_tenant_rows($db), $others_before, 'no other tenant row changed';
};

done_testing;
