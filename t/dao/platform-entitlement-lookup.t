#!/usr/bin/env perl
# ABOUTME: A tenant's platform terms looked up from its in-effect entitlement to payment processing, in registry only.
# ABOUTME: Also a version's own terms by id, so a refund reads the policy of the version stamped on its payment.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;

use Test::Registry::DB;
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO::Tenant;
use Registry::DAO::Resource;
use Registry::DAO::Offer;
use Registry::DAO::Entitlement;
use Registry::PriceOps::PlatformTerms qw( platform_entitlement_terms platform_version_terms );

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# The bootstrap seed's fixed ids.
my $SOLO_V1      = '00000000-0000-0000-0003-000000000001';
my $PLATFORM_PAY = '00000000-0000-0000-0003-000000000002';
my $PAST         = '2020-01-01T00:00:00Z';

# A tenant provisioned the way signup provisions one: the row, then its schema.
sub new_tenant ($slug) {
    my $tenant = Registry::DAO::Tenant->create( $db, { name => "Studio $slug", slug => $slug } );
    $db->query( 'SELECT clone_schema(dest_schema => ?)', $slug );
    return $tenant;
}

# $tenant holds $version's revenue share in registry, from $starts_at.
sub hold ( $tenant, $version = $SOLO_V1, %period ) {
    return Registry::DAO::Entitlement->create( $db, {
        holder_tenant_id => $tenant->id,
        offer_version_id => $version,
        payment_plan_id  => 'revenue_share',
        starts_at        => $PAST,
        %period,
    } );
}

subtest 'solo holder resolves solo v1 terms' => sub {
    hold( new_tenant('solo_studio') );
    my $terms = platform_entitlement_terms( $db, 'solo_studio' );
    is $terms->{id}, $SOLO_V1, 'the offer version id is Solo v1';
    cmp_ok $terms->{fraction}, '==', 0.025, 'the accepted fraction is 2.5%';
    is $terms->{refund_policy}{kind}, 'keep_fee_with_admin_exception', 'the refund policy is v1s';
};

subtest 'platform resolves exactly zero' => sub {
    my $terms = platform_entitlement_terms( $db, 'registry' );
    is $terms->{id}, $PLATFORM_PAY, 'the self-offer version';
    is $terms->{fraction}, 0, 'exactly zero, not undef';
};

subtest 'version id resolves its own terms' => sub {
    my $terms = platform_version_terms( $db, $SOLO_V1 );
    is $terms->{id}, $SOLO_V1, 'the version asked for';
    cmp_ok $terms->{fraction}, '==', 0.025, 'its fraction';
    is $terms->{refund_policy}{kind}, 'keep_fee_with_admin_exception', 'its refund policy';
};

subtest 'no platform entitlement dies naming the tenant' => sub {
    new_tenant('bare_studio');
    my $terms;
    throws_ok { $terms = platform_entitlement_terms( $db, 'bare_studio' ) }
        qr/'bare_studio'/, 'dies naming the tenant';
    ok !defined $terms, 'no Free terms and no 0 come back';
};

subtest 'ended or future entitlement treated as none' => sub {
    hold( new_tenant('ended_studio') )->end( $db, 'expired', 'left', '2021-01-01T00:00:00Z' );
    throws_ok { platform_entitlement_terms( $db, 'ended_studio' ) }
        qr/'ended_studio'/, 'an ended entitlement is none';

    hold( new_tenant('future_studio'), $SOLO_V1, starts_at => '2999-01-01T00:00:00Z' );
    throws_ok { platform_entitlement_terms( $db, 'future_studio' ) }
        qr/'future_studio'/, 'one starting in the future is none';
};

subtest 'lookup is half open at the end instant' => sub {
    my $END = '2021-01-01T00:00:00Z';
    hold( new_tenant('closing_studio'), $SOLO_V1, ends_at => $END );
    is platform_entitlement_terms( $db, 'closing_studio', '2020-12-31T23:59:59Z' )->{id}, $SOLO_V1,
        'in effect just before the end';
    throws_ok { platform_entitlement_terms( $db, 'closing_studio', $END ) }
        qr/'closing_studio'/, 'not in effect at exactly the end instant';
};

subtest 'cloned platform entitlement ignored' => sub {
    my $tenant = new_tenant('cloned_studio');
    my $own    = $tenant->dao($dao)->db;

    # A 0% entitlement to payment processing, recorded in the tenant's own
    # cloned tables, its holder a copy of the tenant's row there.
    $own->insert( 'tenants', { id => $tenant->id, name => $tenant->name, slug => $tenant->slug } );
    my $resource = Registry::DAO::Resource->create( $own,
        { name => 'payment processing', kind => 'unbounded' } );
    my $zero = Registry::DAO::Offer->create( $own, { name => 'Free processing' } )->draft( $own,
        offer_terms( $resource->id, price_cents => 0,
            payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => 0 } ] )
    )->publish($own);
    Registry::DAO::Entitlement->create( $own, {
        holder_tenant_id => $tenant->id,
        offer_version_id => $zero->id,
        payment_plan_id  => 'revenue_share',
        starts_at        => $PAST,
    } );

    throws_ok { platform_entitlement_terms( $own, 'cloned_studio' ) }
        qr/'cloned_studio'/, 'the cloned 0% row is not a platform entitlement';

    hold($tenant);
    cmp_ok platform_entitlement_terms( $own, 'cloned_studio' )->{fraction}, '==', 0.025,
        'registry is read, even on the tenant connection';
};

subtest 'superseded version still resolves its refund policy' => sub {
    my $MOVED  = '2024-01-01T00:00:00Z';
    my $tenant = new_tenant('moving_studio');
    hold($tenant)->end( $db, 'expired', 'moved to Solo v2', $MOVED );

    my $solo = Registry::DAO::Offer->find( $db, { id => '00000000-0000-0000-0002-000000000001' } );
    my $v2   = $solo->draft( $db, offer_terms( '00000000-0000-0000-0001-000000000001',
        price_cents   => 0,
        payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => 0.03 } ],
    ) )->publish($db);
    hold( $tenant, $v2->id, starts_at => $MOVED );

    is platform_entitlement_terms( $db, 'moving_studio' )->{id}, $v2->id, 'the tenant now holds v2';
    my $v1 = {};
    lives_ok { $v1 = platform_version_terms( $db, $SOLO_V1 ) } 'superseded v1 still resolves by id';
    is $v1->{refund_policy}{kind}, 'keep_fee_with_admin_exception', 'v1 by id keeps its own refund policy';
    cmp_ok $v1->{fraction}, '==', 0.025, 'and its own fraction';
};

done_testing;
