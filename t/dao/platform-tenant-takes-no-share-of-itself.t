#!/usr/bin/env perl
# ABOUTME: The platform tenant pays no platform fee on its own sales.
# ABOUTME: Asserted through the revenue-share resolver only, so it outlives how the zero is stored.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;

use Test::Registry::DB;
use Registry::PriceOps::RevenueShare;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

subtest 'the platform takes no fee on its own sale' => sub {
    my $fraction = Registry::PriceOps::RevenueShare::revenue_share_fraction_for_tenant( $dao->db, 'registry' );
    cmp_ok $fraction, '==', 0, 'a sale on registry carries no platform fee';
};

done_testing;
