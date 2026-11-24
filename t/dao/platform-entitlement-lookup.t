#!/usr/bin/env perl
# ABOUTME: A tenant's platform terms looked up from its in-effect entitlement to payment processing, in registry only.
# ABOUTME: Also a version's own terms by id, so a refund reads the policy of the version stamped on its payment.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;

use Test::Registry::DB;
use Registry::DAO::Tenant;
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

done_testing;
