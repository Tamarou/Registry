#!/usr/bin/env perl
# ABOUTME: What the platform actually took on a charge is recorded, not derived from the rate afterwards.
# ABOUTME: Without it a revenue figure is a guess that disagrees with Stripe on every rate change and refund.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Payment;
use Registry::DAO::Tenant;
use Registry::DAO::User;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_platform_revenue';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = $dao->create(User => {
    username => 'rev_parent', name => 'Rev Parent', user_type => 'parent',
    email => 'rev@test.local' });

# The Solo plan the seed ships: 2.5% revenue share.
my $solo = $db->query(
    q{SELECT id FROM registry.pricing_plans WHERE plan_name = 'Solo' LIMIT 1}
)->hash;
ok $solo, 'the seeded Solo plan is there to charge against';

my $tenant = Test::Registry::Fixtures::create_tenant( $db, {
    name => 'Revenue Studio', slug => 'revenue_studio',
} );
$db->query(
    'UPDATE registry.tenants SET platform_pricing_plan_id = ? WHERE id = ?',
    $solo->{id}, $tenant->id );

sub a_completed_payment ( %opts ) {
    my $p = Registry::DAO::Payment->create( $db, {
        user_id => $parent->id, amount_cents => $opts{amount} // 10000,
        status => 'pending',
        metadata => { tenant_slug => 'revenue_studio', enrollment_items => [] },
    } );
    $db->update( 'payments',
        { stripe_payment_intent_id => 'pi_rev_' . $p->id }, { id => $p->id } );
    $p = Registry::DAO::Payment->find( $db, { id => $p->id } );

    # Settled the way both paths settle: through _apply_intent with whatever
    # Stripe reported about the charge.
    $p->_apply_intent( $db, {
        id     => 'pi_rev_' . $p->id,
        status => 'succeeded',
        amount => $opts{amount} // 10000,
        ( exists $opts{fee} ? ( application_fee_amount => $opts{fee} ) : () ),
        metadata => { payment_id => $p->id },
    }, 'pi_rev_' . $p->id );

    return Registry::DAO::Payment->find( $db, { id => $p->id } );
}

subtest 'the fee Stripe reported is what gets recorded' => sub {
    # 2.5% of $100.00, which is what application_fee_cents computes -- but the
    # recorded value comes from the intent, not from recomputing the rate.
    my $payment = a_completed_payment( amount => 10000, fee => 250 );

    is $payment->status, 'completed', 'the payment settled';
    is $payment->platform_fee_cents, 250,
        'and the platform fee is on the row';
    is $payment->platform_pricing_plan_id, $solo->{id},
        'with the plan version it was charged under (#427)';
};

subtest 'an intent that reports no fee records none, rather than a guess' => sub {
    # A registry/platform payment, or any charge with no destination: there is
    # no application fee, and inventing one from the rate would put revenue on
    # the books that Stripe never took.
    my $payment = a_completed_payment( amount => 5000 );

    is $payment->status, 'completed', 'it still settles';
    is $payment->platform_fee_cents, undef,
        'and the fee is NULL -- not recorded, not zero';
};

subtest 'a rate change afterwards does not rewrite history' => sub {
    # The whole reason to record rather than derive. Moving the tenant to a
    # different plan must not re-price what was already charged.
    my $payment = a_completed_payment( amount => 20000, fee => 500 );

    my $empire = $db->query(
        q{SELECT id FROM registry.pricing_plans WHERE plan_name = 'Empire' LIMIT 1}
    )->hash;
    $db->query(
        'UPDATE registry.tenants SET platform_pricing_plan_id = ? WHERE id = ?',
        $empire->{id}, $tenant->id );

    my $after = Registry::DAO::Payment->find( $db, { id => $payment->id } );
    is $after->platform_fee_cents, 500, 'the recorded fee is unchanged';
    is $after->platform_pricing_plan_id, $solo->{id},
        'and still names the plan it was actually charged under';
};

done_testing;
