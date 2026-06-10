#!/usr/bin/env perl
# ABOUTME: Tests the tenant Stripe Connect fields and the readiness predicate
# ABOUTME: used to gate paid enrollment on a usable connected account.
use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Tenant;

my $t   = Test::Registry::DB->new;
my $dao = $t->db;
my $db  = $dao->db;

my $tenant = Registry::DAO::Tenant->create($db, { name => 'Connect Test Org' });

is $tenant->stripe_connect_account_id, undef, 'connected account defaults to undef';
ok !$tenant->stripe_connect_ready, 'not ready with no connected account';

my $updated = $tenant->update($db, {
    stripe_connect_account_id => 'acct_test123',
    stripe_charges_enabled    => 1,
    stripe_details_submitted  => 0,
});
ok !$updated->stripe_connect_ready, 'not ready until details_submitted';

my $ready = $updated->update($db, { stripe_details_submitted => 1 });
ok $ready->stripe_connect_ready, 'ready with account + charges_enabled + details_submitted';

$t->cleanup_test_database;
done_testing;
