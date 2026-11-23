#!/usr/bin/env perl
# ABOUTME: A Stripe account id belongs to one tenant at most, since Connect events are routed by it.
# ABOUTME: Two tenants holding one account would settle a seller's events in the wrong tenant's schema.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;

sub tenant ( $slug, $acct ) {
    $db->query( 'INSERT INTO registry.tenants (name, slug, stripe_connect_account_id) VALUES (?, ?, ?)',
        $slug, $slug, $acct );
}

subtest 'a second tenant cannot hold an account another tenant holds' => sub {
    tenant( 'first_seller', 'acct_shared_one' );
    my $ok = eval { tenant( 'second_seller', 'acct_shared_one' ); 1 };
    ok !$ok, 'the second tenant is refused';
    like $@, qr/unique|duplicate/i, 'by the uniqueness rule';
};

subtest 'tenants without an account are not constrained' => sub {
    my $ok = eval { tenant( 'no_account_a', undef ); tenant( 'no_account_b', undef ); 1 };
    ok $ok, 'any number of tenants may have no account' or diag $@;
};

done_testing;
