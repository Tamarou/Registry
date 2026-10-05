#!/usr/bin/env perl
# ABOUTME: The revenue view sums what was recorded and says how much it could not see.
# ABOUTME: A total that silently omits unrecorded charges is worse than one that admits the gap.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Tenant;
use Registry::DAO::Payment;
use Registry::DAO::User;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = $dao->create(User => {
    username => 'rv_parent', name => 'RV Parent', user_type => 'parent',
    email => 'rv@test.local' });

my $solo = $db->query(
    q{SELECT id FROM registry.pricing_plans WHERE plan_name = 'Solo' LIMIT 1} )->hash;

my $studio = Test::Registry::Fixtures::create_tenant( $db, {
    name => 'Earning Studio', slug => 'earning_studio' } );
$db->query( 'UPDATE registry.tenants SET platform_pricing_plan_id = ?,
             billing_status = ? WHERE id = ?',
    $solo->{id}, 'active', $studio->id );

my $arrears = Test::Registry::Fixtures::create_tenant( $db, {
    name => 'Owing Studio', slug => 'owing_studio' } );
$db->query( 'UPDATE registry.tenants SET platform_pricing_plan_id = ?,
             billing_status = ? WHERE id = ?',
    $solo->{id}, 'past_due', $arrears->id );

# Charges: two recorded, one not. The unrecorded one is every charge made
# before the fee column existed.
sub a_charge ( $slug, $amount, $fee ) {
    my $p = Registry::DAO::Payment->create( $db, {
        user_id => $parent->id, amount_cents => $amount, status => 'completed',
        metadata => { tenant_slug => $slug, enrollment_items => [] },
    } );
    $db->update( 'payments',
        { defined $fee ? ( platform_fee_cents => $fee,
                           platform_pricing_plan_id => $solo->{id} ) : () ,
          completed_at => \'NOW()' },
        { id => $p->id } ) if defined $fee;
    $db->update( 'payments', { completed_at => \'NOW()' }, { id => $p->id } );
    return $p;
}

a_charge( 'earning_studio', 10000, 250 );
a_charge( 'earning_studio', 20000, 500 );
a_charge( 'earning_studio', 30000, undef );   # before the column existed

subtest 'revenue is what was recorded, per tenant' => sub {
    my $revenue = Registry::DAO::Tenant->platform_revenue($db);
    my %by_slug = map { $_->{slug} => $_ } @{ $revenue->{tenants} };

    is $by_slug{earning_studio}{fees_cents}, 750,
        'the recorded fees are summed, and only those';
    is $by_slug{earning_studio}{charges}, 3,
        'all three completed charges are counted';
    is $by_slug{earning_studio}{unrecorded}, 1,
        'and the one with no recorded fee is reported as a gap';
};

subtest 'the total admits what it cannot see' => sub {
    my $revenue = Registry::DAO::Tenant->platform_revenue($db);

    is $revenue->{fees_cents}, 750, 'the platform total is the recorded sum';
    is $revenue->{unrecorded}, 1,
        'with the number of charges it could not account for';

    # The assertion that matters. A total of 750 presented alone implies the
    # platform earned 750; presented with "1 charge unaccounted for" it is an
    # honest lower bound, which is the most that can be said.
    ok $revenue->{unrecorded} > 0,
        'so the figure reads as a floor rather than a fact';
};

subtest 'the rate each tenant is on comes from their plan row' => sub {
    my $revenue = Registry::DAO::Tenant->platform_revenue($db);
    my %by_slug = map { $_->{slug} => $_ } @{ $revenue->{tenants} };

    is $by_slug{earning_studio}{plan_name}, 'Solo', 'the plan is named';
    is $by_slug{earning_studio}{rate_pct} + 0, 2.5,
        'at the rate that plan actually declares, not a constant';
};

subtest 'arrears are surfaced' => sub {
    # #426: billing_status of past_due or incomplete with nothing surfacing it.
    my $revenue = Registry::DAO::Tenant->platform_revenue($db);

    is_deeply [ map { $_->{slug} } @{ $revenue->{arrears} } ], ['owing_studio'],
        'a past_due tenant is listed';
};

done_testing;
