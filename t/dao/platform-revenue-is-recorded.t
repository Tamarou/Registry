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

subtest 'a payment with no seller account records no fee, rather than a guess' => sub {
    # No Connect params were ever sent: there is no application fee to know
    # about, and inventing one -- even 0 -- would claim a charge we never made.
    my $payment = a_completed_payment( amount => 5000 );

    is $payment->status, 'completed', 'it still settles';
    is $payment->platform_fee_cents, undef,
        'and the fee is NULL -- not recorded, not zero';
};

subtest 'a connected-account charge with a zero fee records 0, not a gap' => sub {
    # Stripe omits a zero application_fee_amount (564b6a1), so a Free-plan
    # charge comes back with none. That is a recorded $0, not missing data.
    my $free = $db->query( q{SELECT id FROM registry.pricing_plans
        WHERE plan_scope = 'platform' AND metadata->>'default' = 'true'
          AND superseded_at IS NULL} )->hash;
    Test::Registry::Fixtures::create_tenant( $db, {
        name => 'Free Studio', slug => 'free_studio' } );
    $db->query( q{UPDATE registry.tenants SET platform_pricing_plan_id = ?,
                  stripe_connect_account_id = 'acct_free_studio' WHERE slug = 'free_studio'},
        $free->{id} );
    $db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)',
        'free_studio', $parent->id );
    my $tdb = $dao->connect_schema('free_studio')->db;

    my $p = Registry::DAO::Payment->create( $tdb, {
        user_id => $parent->id, amount_cents => 10000, status => 'pending',
        metadata => { tenant_slug => 'free_studio', enrollment_items => [] },
    } );
    $tdb->update( 'payments',
        { stripe_payment_intent_id => 'pi_free_' . $p->id }, { id => $p->id } );
    $p = Registry::DAO::Payment->find( $tdb, { id => $p->id } );

    # The parent-return path (process_payment -> _apply_intent): no fee reported.
    $p->_apply_intent( $tdb, {
        id => 'pi_free_' . $p->id, status => 'succeeded', amount => 10000,
        metadata => { payment_id => $p->id },
    }, 'pi_free_' . $p->id );

    my $row = Registry::DAO::Payment->find( $tdb, { id => $p->id } );
    is $row->status, 'completed', 'the charge settled';
    is $row->platform_fee_cents, 0, 'and the fee is recorded as 0';
    is $row->platform_pricing_plan_id, $free->{id}, 'under the plan it was charged on';

    my ($t) = grep { $_->{slug} eq 'free_studio' }
        @{ Registry::DAO::Tenant->platform_revenue($db)->{tenants} };
    is $t->{charges}, 1, 'the revenue view counts the charge';
    is $t->{unrecorded}, 0, 'as recorded, not as a gap';
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
