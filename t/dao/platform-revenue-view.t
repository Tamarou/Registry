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
#
# These go into the TENANT's schema, because that is the only place a real one
# ever goes: `tenant-scoped-payments` moved payments out of registry, and
# Registry::DAO::Payment's SQL is unqualified throughout, so it resolves through
# whatever search_path its $db carries. Writing these through the registry $db
# instead would fabricate rows in registry.payments that no code path produces,
# and then assert against them -- which is how this screen came to report a
# confident total while reading a table production never fills.
# <tenant>.payments.user_id references <tenant>.users, so the payer has to be
# resident there first. copy_user is not idempotent -- a second call trips
# users_pkey -- so do it once per tenant.
my %resident;
sub resident ( $slug ) {
    return if $resident{$slug}++;
    $db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)',
        $slug, $parent->id );
}

sub a_charge ( $slug, $amount, $fee ) {
    resident($slug);
    my $tenant_db = $dao->connect_schema($slug)->db;
    my $p = Registry::DAO::Payment->create( $tenant_db, {
        user_id => $parent->id, amount_cents => $amount, status => 'completed',
        metadata => { tenant_slug => $slug, enrollment_items => [] },
    } );
    $tenant_db->update( 'payments',
        { defined $fee ? ( platform_fee_cents => $fee,
                           platform_pricing_plan_id => $solo->{id} ) : () ,
          completed_at => \'NOW()' },
        { id => $p->id } );
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

subtest 'a charge written where production writes it is counted' => sub {
    # Pins the schema the money is read from, which is the defect this test
    # exists for. Registry::DAO::Payment holds no reference to
    # registry.payments, so a real charge and its platform_fee_cents land in
    # <tenant>.payments; a reader pointed at registry.payments finds nothing and
    # says zero.
    #
    # Webhooks.pm:330 and PricingRelationships.pm:228 both already warn about
    # exactly this: a registry-scoped query "would hit registry.payments, match
    # no rows, and return quietly".
    my $slug = 'earning_studio';

    my $tenant_db = $dao->connect_schema($slug)->db;
    my $real = Registry::DAO::Payment->create( $tenant_db, {
        user_id      => $parent->id,
        amount_cents => 40000,
        status       => 'completed',
        metadata     => { tenant_slug => $slug, enrollment_items => [] },
    } );
    $tenant_db->update( 'payments',
        { platform_fee_cents       => 1000,
          platform_pricing_plan_id => $solo->{id},
          completed_at             => \'NOW()' },
        { id => $real->id } );

    # It is in the tenant schema and not in registry -- the premise of the test.
    is $tenant_db->query(
        'SELECT platform_fee_cents FROM payments WHERE id = ?', $real->id
    )->hash->{platform_fee_cents}, 1000, 'the fee is recorded in the tenant schema';
    is $db->query(
        'SELECT COUNT(*) AS n FROM registry.payments WHERE id = ?', $real->id
    )->hash->{n}, 0, 'and the row is NOT in registry.payments';

    my $revenue = Registry::DAO::Tenant->platform_revenue($db);
    my ($row) = grep { $_->{slug} eq $slug } @{ $revenue->{tenants} };
    ok $row, 'the tenant is listed';
    is $row->{fees_cents}, 1750,
        'the tenant total includes the charge production actually wrote';
};

subtest 'a tenant whose schema cannot be read is named, not counted as zero' => sub {
    # A schema row that exists with its payments table missing: worse than a
    # tenant with no schema at all, because every total silently assumes
    # otherwise. fleet() reports it as a provisioning fault; here the point is
    # that the money total must not quietly absorb it as 0 and must not take
    # the page down either.
    my $broken = Registry::DAO::Tenant->create( $db, {
        name => 'Half Provisioned', slug => 'half_provisioned' } );
    $db->query('CREATE SCHEMA IF NOT EXISTS half_provisioned');

    my $revenue = Registry::DAO::Tenant->platform_revenue($db);

    my ($named) = grep { $_->{slug} eq 'half_provisioned' }
                       @{ $revenue->{unreadable} };
    ok $named, 'the unreadable tenant is named';
    like $named->{error}, qr/\S/, 'with the reason it could not be read';

    my %by_slug = map { $_->{slug} => $_ } @{ $revenue->{tenants} };
    ok $by_slug{half_provisioned}{unreadable},
        'and its row carries the same, so the table can mark it';

    # The earlier tenant's money is still reported: one broken schema must not
    # cost the operator every other figure, which is what psql does.
    is $by_slug{earning_studio}{fees_cents}, 1750,
        'a readable tenant is still totalled';
};

done_testing;
