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
        qr/entitlements_coalesce_offer_id_in_effect_excl/,
        'a newer version of the same offer starting inside the first phase is refused';
};

subtest 'adjacent schedule phases accepted' => sub {
    my %clay = tenant('clay_two');
    my $v1   = new_offer( $db, 'Solo adjacent' );
    my $v2   = next_version( $db, $v1 );
    hold( $db, $v1, $DEC, $DEC15, %clay );

    lives_ok { hold( $db, $v2, $DEC15, undef, %clay ) }
        'a newer version starting where the first phase ends is accepted';
};

subtest 'schedule phases of different offers accepted' => sub {
    my %clay = tenant('clay_three');
    hold( $db, new_offer( $db, 'Solo A' ), $DEC, undef, %clay );

    lives_ok { hold( $db, new_offer( $db, 'Solo B' ), $DEC, undef, %clay ) }
        'the same holder holds a second offer over the same period';
};

# A person in $handle's schema, as a holder.
sub person ( $handle, $name ) {
    return ( holder_user_id => $handle->insert( 'users', { username => $name }, { returning => 'id' } )->hash->{id} );
}

# A tenant provisioned the way signup provisions one: the row, then its schema.
sub new_tenant ($slug) {
    Registry::DAO::Tenant->create( $db, { name => "Studio $slug", slug => $slug } );
    $db->query( 'SELECT clone_schema(dest_schema => ?)', $slug );
    return Registry::DAO->new( url => $dao->url, schema => $slug )->db;
}

my $studio = new_tenant('wheel_room');

subtest 'discrete entitlements are not excluded by the schedule-phase constraint' => sub {
    my %sam  = person( $studio, 'sam' );
    my $seat = new_offer( $studio, 'Wheel class', 'discrete' );
    hold( $studio, $seat, $DEC, $JAN, %sam );

    lives_ok { hold( $studio, $seat, $DEC15, undef, %sam ) }
        'a second one-time entitlement to the same offer over an overlapping period is accepted';
};

subtest 'constraint present in a new tenant schema' => sub {
    my $fresh = new_tenant('glaze_room');
    ok $fresh->query( q{
        SELECT 1 FROM pg_constraint
         WHERE conrelid = 'glaze_room.entitlements'::regclass
           AND conname = 'entitlements_coalesce_offer_id_in_effect_excl' AND contype = 'x'
    } )->rows, 'the new schema has the exclusion constraint';

    my %pat     = person( $fresh, 'pat' );
    my $members = new_offer( $fresh, 'Membership' );
    hold( $fresh, $members, $DEC, undef, %pat );
    throws_ok { hold( $fresh, next_version( $fresh, $members ), $DEC15, undef, %pat ) }
        qr/entitlements_coalesce_offer_id_in_effect_excl/, 'and refuses an overlapping phase there';
};

done_testing;
