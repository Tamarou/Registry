#!/usr/bin/env perl
# ABOUTME: One schedule phase in effect at a time per holder and offer, enforced by an exclusion constraint.
# ABOUTME: Schedule-type (percentage-of-sales) entitlements only; discrete one-time entitlements are never refused by it.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Test::Registry::DB;
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO::Resource;
use Registry::DAO::Offer;
use Registry::DAO::Entitlement;
use Registry::DAO::Tenant;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# Solo's plan is a schedule; a seat's is discrete.
my %PLAN = (
    schedule => [ { id => 'plan', kind => 'percentage_of_sales', fraction => '0.0300' } ],
    discrete => [ { id => 'plan', kind => 'one_time' } ],
);

# The first published version of a new offer in $handle's schema, on a $type plan.
sub new_offer ( $handle, $name, $type = 'schedule' ) {
    my $resource = Registry::DAO::Resource->create( $handle, { name => "$name resource", kind => 'unbounded' } );
    return Registry::DAO::Offer->create( $handle, { name => $name } )
        ->draft( $handle, offer_terms( $resource->id, payment_plans => $PLAN{$type} ) )->publish($handle);
}

# The next published version of $version's offer, on a $type plan.
sub next_version ( $handle, $version, $type = 'schedule' ) {
    return Registry::DAO::Offer->find( $handle, { id => $version->offer_id } )
        ->draft( $handle, offer_terms( $version->resource_id, payment_plans => $PLAN{$type} ) )->publish($handle);
}

# An entitlement of %holder (one holder column => id) to $version over [$starts, $ends).
sub hold ( $handle, $version, $starts, $ends, %holder ) {
    return Registry::DAO::Entitlement->create( $handle, {
        %holder,
        offer_version_id => $version->id,
        payment_plan_id  => 'plan',
        starts_at        => $starts,
        ends_at          => $ends,
    } );
}

# A tenant, held in registry as a holder of the platform's offers.
sub tenant ($slug) {
    return ( holder_tenant_id => Registry::DAO::Tenant->create( $db, { name => "Studio $slug", slug => $slug } )->id );
}

my ( $DEC, $DEC15, $JAN ) = ( '2026-12-01T00:00:00Z', '2026-12-15T00:00:00Z', '2027-01-01T00:00:00Z' );

subtest 'overlapping schedule phases refused' => sub {
    my %clay = tenant('clay_one');
    my $v1   = new_offer( $db, 'Solo' );
    my $v2   = next_version( $db, $v1 );
    hold( $db, $v1, $DEC, $JAN, %clay );

    throws_ok { hold( $db, $v2, $DEC15, undef, %clay ) }
        qr/entitlements_one_schedule_phase/,
        'a newer version of the same offer starting inside the first phase is refused';
};

done_testing;
