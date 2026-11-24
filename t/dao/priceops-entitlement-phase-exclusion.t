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

my $EXCL = qr/entitlements_coalesce_offer_id_in_effect_excl/;
my $FEB  = '2027-02-01T00:00:00Z';

subtest 'open ended phase blocks a later phase' => sub {
    my %clay = tenant('clay_four');
    my $v1   = new_offer( $db, 'Solo open' );
    hold( $db, $v1, $DEC, undef, %clay );

    throws_ok { hold( $db, next_version( $db, $v1 ), $JAN, $FEB, %clay ) }
        $EXCL, 'a phase starting long after an open-ended one is refused';
};

subtest 'one microsecond overlap refused' => sub {
    my %clay = tenant('clay_five');
    my $v1   = new_offer( $db, 'Solo tight' );
    hold( $db, $v1, $DEC, $JAN, %clay );

    throws_ok { hold( $db, next_version( $db, $v1 ), '2026-12-31T23:59:59.999999Z', undef, %clay ) }
        $EXCL, 'a phase starting one microsecond before the first ends is refused';
};

subtest 'update extending a phase refused' => sub {
    my %clay  = tenant('clay_six');
    my $v1    = new_offer( $db, 'Solo extend' );
    my $first = hold( $db, $v1, $DEC, $DEC15, %clay );
    hold( $db, next_version( $db, $v1 ), $DEC15, undef, %clay );

    throws_ok {
        $db->query( q{UPDATE entitlements SET in_effect = tstzrange(?, ?, '[)') WHERE id = ?},
            $DEC, $JAN, $first->id )
    } $EXCL, "moving the first phase's end into the next phase is refused";
};

subtest 'concurrent overlapping inserts leave one' => sub {
    my %clay = tenant('clay_seven');
    my $v1   = new_offer( $db, 'Solo race' );
    my $v2   = next_version( $db, $v1 );
    my $insert = q{INSERT INTO registry.entitlements
        (holder_tenant_id, offer_version_id, payment_plan_id, in_effect)
        VALUES (?, ?, 'plan', tstzrange(?, NULL, '[)'))};

    my ( $one, $two ) = map { Mojo::Pg->new( $dao->url )->db } 1 .. 2;
    my $tx = $one->begin;
    $one->query( $insert, $clay{holder_tenant_id}, $v1->id, $DEC );

    # The second waits on the first's uncommitted row, then sees it committed.
    my $second_error;
    $two->query( $insert, $clay{holder_tenant_id}, $v2->id, $DEC15,
        sub ( $db, $err, $res ) { $second_error = $err; Mojo::IOLoop->stop } );
    Mojo::IOLoop->timer( 0.2 => sub { $tx->commit } );
    Mojo::IOLoop->start;

    like $second_error, $EXCL, 'the second insert is refused once the first commits';
    is $db->query( 'SELECT count(*) FROM entitlements WHERE holder_tenant_id = ?',
        $clay{holder_tenant_id} )->array->[0], 1, 'exactly one phase is committed';
};

subtest 'two tenants hold solo concurrently' => sub {
    my $solo = new_offer( $db, 'Solo shared' );
    hold( $db, $solo, $DEC, undef, tenant('clay_eight') );

    lives_ok { hold( $db, $solo, $DEC, undef, tenant('clay_nine') ) }
        'a second tenant holds the same Solo version over the same period';
};

subtest 'siblings hold the same offer concurrently' => sub {
    my %parent = person( $studio, 'pat' );
    my $child  = sub ($name) {
        return (
            holder_family_member_id => $studio->insert( 'family_members',
                { family_id => $parent{holder_user_id}, child_name => $name, birth_date => '2018-05-01' },
                { returning => 'id' } )->hash->{id},
            payer_user_id => $parent{holder_user_id},
        );
    };
    my $club = new_offer( $studio, 'Clay club' );
    hold( $studio, $club, $DEC, undef, $child->('Kit') );

    lives_ok { hold( $studio, $club, $DEC, undef, $child->('Kai') ) }
        "the payer's second child holds the same offer over the same period";
};

done_testing;
