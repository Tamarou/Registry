#!/usr/bin/env perl
# ABOUTME: A tenant's platform fee comes only from its in-effect platform entitlement: absence is refused, never 0%.
# ABOUTME: The platform resolves to exactly 0 through its self-offer, and a Solo holder is charged Solo's stamped rate.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Offers qw( offer_terms );
use Test::Registry::PricingProbe qw( give_tenant_terms with_tenant_plan );
use Registry::DAO;
use Registry::DAO::Offer;
use Registry::DAO::Resource;
use Registry::DAO::Entitlement;
use Registry::DAO::Payment;
use Registry::DAO::User;
use Registry::PriceOps::RevenueShare qw( revenue_share_fraction_for_tenant );

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $SOLO_V1 = '00000000-0000-0000-0003-000000000001';

# A tenant with its own schema, a Connect account and a parent who pays.
my $n = 0;
sub connect_ready_tenant ($name) {
    my $slug   = $name . '_' . ++$n;
    my $tenant = Test::Registry::Fixtures::create_tenant( $db, { name => $name, slug => $slug } );
    $db->query( 'UPDATE registry.tenants SET stripe_connect_account_id = ?, stripe_charges_enabled = TRUE,
                        stripe_details_submitted = TRUE WHERE slug = ?', "acct_$slug", $slug );
    my $tdb    = $dao->connect_schema($slug)->db;
    my $parent = Registry::DAO::User->create( $tdb, {
        username => "${slug}_parent", email => "${slug}_parent\@test.local",
        name => 'Paying Parent', user_type => 'parent' } );
    return { slug => $slug, id => $tenant->id, db => $tdb, parent => $parent->id };
}

sub hold_solo_v1 ($tenant) {
    return Registry::DAO::Entitlement->create( $db, {
        holder_tenant_id => $tenant->{id}, offer_version_id => $SOLO_V1,
        payment_plan_id  => 'revenue_share', starts_at => '2020-01-01T00:00:00Z' } );
}

# Quotes a 10000-cent charge to $tenant. Platform terms are resolved and
# stamped when the payment is created, before any intent goes to Stripe, so a
# refusal here means nothing reached Stripe. Returns the error when refused.
sub charge ($tenant) {
    my $payment;
    my $ok = eval {
        $payment = Registry::DAO::Payment->create( $tenant->{db}, {
            user_id  => $tenant->{parent}, amount_cents => 10000,
            metadata => { tenant_slug => $tenant->{slug}, enrollment_items => [] } } );
        1;
    };
    return $ok ? ( undef, $payment ) : ( $@, undef );
}

subtest 'tenant with no platform entitlement refused before stripe' => sub {
    my $tenant = connect_ready_tenant('no_terms');

    ok !eval { revenue_share_fraction_for_tenant( $db, $tenant->{slug} ); 1 }, 'the resolver refuses';
    like $@, qr/\Q'$tenant->{slug}'\E/, 'naming the tenant';
    unlike $@, qr/Free plan/, 'with no fallback to the Free plan';

    my ($err) = charge($tenant);
    like $err, qr/\Q'$tenant->{slug}'\E holds no platform entitlement/,
        'the charge is refused naming the tenant, before any intent reaches Stripe';
};

subtest 'platform tenant resolves to zero' => sub {
    is revenue_share_fraction_for_tenant( $db, 'registry' ), 0, 'the platform takes exactly 0 of its own sales';
    is revenue_share_fraction_for_tenant( $dao->connect_schema('registry')->db, 'registry' ), 0,
        'on any connection';
};

subtest 'solo holder charged its stamped rate' => sub {
    my $tenant = connect_ready_tenant('solo_holder');
    hold_solo_v1($tenant);

    is revenue_share_fraction_for_tenant( $db, $tenant->{slug} ), '0.025', 'the resolver answers Solo v1 rate';

    my ( $err, $payment ) = charge($tenant);
    is $err, undef, 'the charge is made';
    is $payment->metadata->{revenue_share_fraction}, '0.025', 'the payment carries the exact rate';
    is $payment->metadata->{platform_offer_version_id}, $SOLO_V1, 'and the version it was priced under';
    is $payment->metadata->{stripe_account_id}, "acct_$tenant->{slug}", 'on the tenant account';
    is_deeply { Registry::DAO::Payment::_connect_params( $tenant->{db}, $payment->metadata, 10000 ) },
        { application_fee_amount => 250 }, 'its intent takes 2.5% of 10000 cents';

    # Stripe's side -- a real Solo charge carrying the fee, refunded with the
    # fee kept -- is proved in t/stripe-live/platform-fee-refund-exception.t.
    is $payment->stamped_platform_terms($db)->{refund_policy}{kind}, 'keep_fee_with_admin_exception',
        'the stamped version keeps the fee on a refund';
};

# A charge refused for want of platform terms: the resolver dies naming the
# tenant, nothing reaches Stripe, and no payment or fee row is written.
sub refused_like_none ( $tenant, $label ) {
    ok !eval { revenue_share_fraction_for_tenant( $db, $tenant->{slug} ); 1 }, "$label: the resolver refuses";
    like $@, qr/\Q'$tenant->{slug}'\E holds no platform entitlement/, "$label: naming the tenant";
    my ($err) = charge($tenant);
    like $err, qr/\Q'$tenant->{slug}'\E holds no platform entitlement/,
        "$label: the charge is refused before any intent reaches Stripe";
}

subtest 'ended or future platform entitlement refused a charge' => sub {
    my $ended = connect_ready_tenant('ended_terms');
    hold_solo_v1($ended)->end( $db, 'refunded', 're_ended_terms' );
    refused_like_none( $ended, 'ended by a refund' );

    my $future = connect_ready_tenant('future_terms');
    Registry::DAO::Entitlement->create( $db, {
        holder_tenant_id => $future->{id}, offer_version_id => $SOLO_V1,
        payment_plan_id  => 'revenue_share', starts_at => '2999-01-01T00:00:00Z' } );
    refused_like_none( $future, 'starting in the future' );
};

subtest 'cloned zero entitlement still refused' => sub {
    my $tenant = connect_ready_tenant('cloned_terms');
    my $own    = $tenant->{db};

    # A 0% entitlement to payment processing in the tenant's own cloned tables,
    # its holder a copy of the tenant's row there.
    $own->insert( 'tenants', { id => $tenant->{id}, name => 'cloned_terms', slug => $tenant->{slug} } );
    my $resource = Registry::DAO::Resource->create( $own, { name => 'payment processing', kind => 'unbounded' } );
    my $zero = Registry::DAO::Offer->create( $own, { name => 'Free processing' } )->draft( $own,
        offer_terms( $resource->id, price_cents => 0,
            payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => 0 } ] )
    )->publish($own);
    Registry::DAO::Entitlement->create( $own, {
        holder_tenant_id => $tenant->{id}, offer_version_id => $zero->id,
        payment_plan_id  => 'revenue_share', starts_at => '2020-01-01T00:00:00Z' } );

    refused_like_none( $tenant, 'a 0% row in its own schema' );
};

subtest 'refused charge writes no rows' => sub {
    my $tenant = connect_ready_tenant('rowless_terms');
    my ($err) = charge($tenant);
    ok $err, 'the charge is refused';
    is $tenant->{db}->query('SELECT count(*) FROM payments')->array->[0], 0, 'no payment row is written';
    is $tenant->{db}->query('SELECT count(*) FROM payments WHERE platform_fee_cents IS NOT NULL')->array->[0], 0,
        'and no platform fee row';
};

subtest 'probe never edits solo v1' => sub {
    my $solo = sub {
        $db->query( q{SELECT v.*, p.kind, p.fraction FROM registry.offer_versions v
                        JOIN registry.offer_version_payment_plans p ON p.offer_version_id = v.id
                       WHERE v.id = ?}, $SOLO_V1 )->hashes->to_array;
    };
    my $before = $solo->();

    my $tenant = connect_ready_tenant('probed_terms');
    hold_solo_v1($tenant);
    with_tenant_plan( $db, $tenant->{slug}, { rate => '0.0999', amount_cents => 7 }, sub {
        is revenue_share_fraction_for_tenant( $db, $tenant->{slug} ), '0.0999', 'the probe states its terms';
    } );
    give_tenant_terms( $db, $tenant->{slug}, { rate => '0.0042' } );

    is_deeply $solo->(), $before, "Solo v1's terms and publication are unchanged";
    is $db->query( q{SELECT id FROM registry.offer_versions WHERE offer_id = ? AND published_at IS NOT NULL
                       AND superseded_at IS NULL}, $before->[0]{offer_id} )->array->[0],
        '2f570c64-dad4-c0aa-5848-3219eb752c76', "and Solo's current version is still solo-grants-session-workflows'";
};

subtest 'refund reads the stamped versions policy' => sub {
    my $tenant = connect_ready_tenant('moving_terms');
    my $v1 = hold_solo_v1($tenant);
    my ( undef, $under_v1 ) = charge($tenant);

    # The tenant moves to later terms whose refund policy has no admin
    # exception: v1's phase ends where the new one begins.
    $db->query( 'UPDATE registry.entitlements SET in_effect = tstzrange(lower(in_effect), now()) WHERE id = ?',
        $v1->id );
    my $later = Registry::DAO::Offer->find( $db, { id => '00000000-0000-0000-0002-000000000001' } )->draft( $db,
        offer_terms( '00000000-0000-0000-0001-000000000001', price_cents => 0,
            payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => '0.03' } ] ) )
        ->publish($db);
    Registry::DAO::Entitlement->create( $db, {
        holder_tenant_id => $tenant->{id}, offer_version_id => $later->id,
        payment_plan_id  => 'revenue_share', starts_at => 'now' } );
    my ( undef, $under_later ) = charge($tenant);

    is $under_v1->stamped_platform_terms($db)->{refund_policy}{kind}, 'keep_fee_with_admin_exception',
        "the v1 payment reads v1's refund policy";
    is $under_later->stamped_platform_terms($db)->{refund_policy}{kind}, 'none',
        "the later payment reads its own";

    # Returning the platform's fee is the admin exception v1's policy carries.
    # A zero amount is refused only after the policy gate and before any Stripe
    # call, so the reason shows which gate stopped each payment. The fee being
    # returned under v1's policy is proved in t/stripe-live/platform-fee-refund-exception.t.
    for my $p ( $under_v1, $under_later ) {
        $tenant->{db}->update( 'payments', { status => 'completed', stripe_payment_intent_id => 'pi_' . $p->id },
            { id => $p->id } );
    }
    my $refused = sub ($p) {
        my $payment = Registry::DAO::Payment->find( $tenant->{db}, { id => $p->id } );
        return eval { $payment->refund_platform_fee_async( $tenant->{db}, { amount_cents => 0 } ); 1 } ? '' : $@;
    };

    like $refused->($under_v1), qr/REFUND_NOT_SENT.*not a positive whole number/s,
        'the v1 payment passes its refund policy';
    like $refused->($under_later), qr/REFUND_NOT_SENT.*refund policy/s,
        'the later payment is refused by its own stamped refund policy, before Stripe';
};

done_testing;
