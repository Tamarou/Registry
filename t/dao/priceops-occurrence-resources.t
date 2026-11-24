#!/usr/bin/env perl
# ABOUTME: Each occurrence (an events row) is its own finite resource, and a class offer covers its class's occurrences.
# ABOUTME: An entitlement under a class offer holds units of one covered occurrence; the others are its change targets.
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
use Registry::DAO::OfferVersion;
use Registry::DAO::Project;
use Registry::DAO::Entitlement;
use Registry::DAO::Tenant;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my %studio;
for my $slug (qw( wheel_house kiln_house )) {
    Registry::DAO::Tenant->create( $db, { name => $slug, slug => $slug } );
    $db->query( 'SELECT clone_schema(dest_schema => ?)', $slug );
    $studio{$slug} = Registry::DAO->new( url => $dao->url, schema => $slug )->db;
}
my $studio = $studio{wheel_house};

my $made = 0;

# A class (a projects row) in $handle; returns its id.
sub class_in ( $handle = $studio, %more ) {
    return $handle->insert( 'projects', { name => 'Class ' . ++$made, slug => "class-$made", %more },
        { returning => 'id' } )->hash->{id};
}

# An occurrence of $class at $time for $duration minutes; returns its id.
sub event_of ( $class, $time = '2099-03-0' . ( $made % 9 + 1 ) . 'T10:00:00Z', %more ) {
    my $handle  = delete $more{handle} // $studio;
    my $teacher = $handle->insert( 'users', { username => 'teacher-' . ++$made }, { returning => 'id' } )
        ->hash->{id};
    my $where = $handle->insert( 'locations', { name => "Room $made", slug => "room-$made" },
        { returning => 'id' } )->hash->{id};
    return $handle->insert( 'events', {
        project_id  => $class,
        location_id => $where,
        teacher_id  => $teacher,
        time        => $time,
        duration    => 90,
        capacity    => 10,
        %more,
    }, { returning => 'id' } )->hash->{id};
}

# Whether two instants, as Postgres or ISO 8601 text, are the same instant.
sub same_instant ( $got, $want ) {
    return $studio->query( 'SELECT ?::timestamptz = ?::timestamptz', $got, $want )->array->[0];
}

subtest 'an occurrence is its own finite resource' => sub {
    my $event    = event_of( class_in(), '2099-03-01T10:00:00Z', duration => 90, capacity => 10 );
    my $resource = Registry::DAO::Resource->for_occurrence( $studio, $event );
    is $resource->kind,     'finite', 'finite';
    is $resource->capacity, 10,       "the event's seats";
    is $resource->event_id, $event,   'bound to its event';

    my ( $starts, $ends ) = $resource->occurrence_window($studio);
    ok same_instant( $starts, '2099-03-01T10:00:00Z' ), "starts at the event's time";
    ok same_instant( $ends,   '2099-03-01T11:30:00Z' ), 'ends duration minutes later';
};

# The published class offer version for $class, with day-one terms.
sub class_offer ( $class, %more ) {
    return Registry::DAO::Offer->create( $studio, { name => 'Wheel class ' . ++$made } )
        ->draft( $studio, offer_terms( undef, class_project_id => $class, %more ) )->publish($studio);
}

# Occurrence-resource ids, sorted, for comparing sets.
sub ids (@resources) { [ sort map { $_->id } @resources ] }

subtest 'class offer covers current and later occurrences' => sub {
    my $c = class_in( $studio, seats_per_occurrence => 12 );
    is( Registry::DAO::Project->find( $studio, { id => $c } )->seats_per_occurrence, 12,
        'the class record holds its default seats per occurrence' );

    my @now   = map { Registry::DAO::Resource->for_occurrence( $studio, event_of($c) ) } 1 .. 2;
    my $other = Registry::DAO::Resource->for_occurrence( $studio, event_of( class_in() ) );
    my $offer = class_offer($c);
    is $offer->resource_id, undef, 'a class offer names no single resource';

    my $later = Registry::DAO::Resource->for_occurrence( $studio, event_of($c) );
    is_deeply ids( $offer->covered_resources($studio)->@* ), ids( @now, $later ),
        "covers the class's occurrences, the later one too";
    ok $offer->buys( $studio, $_->id ), 'buys ' . $_->name for @now, $later;
    ok !$offer->buys( $studio, $other->id ), 'not an occurrence of another class';
    is( Registry::DAO::OfferVersion->find( $studio, { offer_id => $offer->offer_id } )->version, 1,
        'with no new version' );
};

sub person () {
    return $studio->insert( 'users', { username => 'holder-' . ++$made }, { returning => 'id' } )
        ->hash->{id};
}

# A class, its published class offer and $n occurrence-resources of it.
sub class_with_occurrences ( $n = 3 ) {
    my $c     = class_in();
    my @occ   = map { Registry::DAO::Resource->for_occurrence( $studio, event_of($c) ) } 1 .. $n;
    my $offer = class_offer( $c, units_per_acceptance => 2 );
    return ( $offer, @occ );
}

# A grant of $units seats of $resource under $offer to $holder.
sub seat_sale ( $offer, $resource, $holder, $units = 2 ) {
    return {
        holder_user_id   => $holder,
        offer_version_id => $offer->id,
        payment_plan_id  => 'pay',
        resource_id      => $resource->id,
        units            => $units,
        starts_at        => '2020-01-01T00:00:00Z',
    };
}

subtest 'entitlement holds units of one covered occurrence' => sub {
    my ( $offer, $a, $b ) = class_with_occurrences(2);
    my $holder = person();
    my $e      = Registry::DAO::Entitlement->grant( $studio, seat_sale( $offer, $a, $holder ) );
    is_deeply $e->units( $studio, $a->id ), [ 1, 2 ], 'a couple holds two seats of the occurrence';
    is_deeply $e->units( $studio, $b->id ), [], 'and none of another';
    ok Registry::DAO::Entitlement->holds_unit_of( $studio, $holder, $a->id ), 'holds a seat in it';
    ok !Registry::DAO::Entitlement->holds_unit_of( $studio, $holder, $b->id ), 'not in the other';
    is $b->free_units($studio), 10, "the other occurrence's seats are untouched";
};

subtest 'one holder holds seats in two occurrences of one class offer' => sub {
    my ( $offer, $a, $b ) = class_with_occurrences(2);
    my $holder = person();
    my @e = map { Registry::DAO::Entitlement->grant( $studio, seat_sale( $offer, $_, $holder ) ) } $a, $b;
    isnt $e[0]->id, $e[1]->id, 'two entitlements';
    is $e[0]->offer_version_id, $e[1]->offer_version_id, 'under one class offer version';
    ok Registry::DAO::Entitlement->holds_unit_of( $studio, $holder, $_->id ), 'holds a seat in ' . $_->name
        for $a, $b;
};

subtest 'change targets are the other covered occurrences' => sub {
    my ( $offer, @occ ) = class_with_occurrences(3);
    Registry::DAO::Resource->for_occurrence( $studio, event_of( class_in() ) );    # another class's
    my $e = Registry::DAO::Entitlement->grant( $studio, seat_sale( $offer, $occ[1], person() ) );
    is_deeply ids( $e->change_targets($studio)->@* ), ids( @occ[ 0, 2 ] ),
        'the other occurrences its stamped version covers, not its own';
};

# How many entitlements $holder has.
sub held_by ($holder) { scalar( () = Registry::DAO::Entitlement->held_by( $studio, $holder ) ) }

subtest 'units of an uncovered occurrence refused' => sub {
    my ($offer) = class_with_occurrences(1);
    my $elsewhere = Registry::DAO::Resource->for_occurrence( $studio, event_of( class_in() ) );
    my $holder    = person();
    throws_ok { Registry::DAO::Entitlement->grant( $studio, seat_sale( $offer, $elsewhere, $holder ) ) }
        qr/does not buy resource/, "an occurrence of another class is refused";
    is held_by($holder), 0, 'and leaves no entitlement';
    is $elsewhere->free_units($studio), 10, 'nor any held seat';
};

subtest 'occurrence from another tenant schema refused' => sub {
    my $kiln  = $studio{kiln_house};
    my $there = event_of( class_in($kiln), '2099-04-01T10:00:00Z', handle => $kiln );
    throws_ok {
        $studio->insert( 'resources',
            { name => 'Borrowed', kind => 'finite', capacity => 10, event_id => $there } )
    } qr/resources_event_id_fkey/, "another tenant's event is no occurrence here";
    throws_ok { Registry::DAO::Resource->for_occurrence( $studio, $there ) } qr/no event/,
        'and the DAO finds no such event';
};

subtest 'second resource for one occurrence refused' => sub {
    my $event = event_of( class_in() );
    Registry::DAO::Resource->for_occurrence( $studio, $event );
    throws_ok { Registry::DAO::Resource->for_occurrence( $studio, $event ) }
        qr/resources_event_id_key/, 'one occurrence has one resource';
};

subtest 'entitlement spanning two occurrences refused' => sub {
    my ( $offer, $a, $b ) = class_with_occurrences(2);
    my $holder = person();
    throws_ok {
        my $tx = $studio->begin;
        my $e  = Registry::DAO::Entitlement->create( $studio, {
            holder_user_id   => $holder,
            offer_version_id => $offer->id,
            payment_plan_id  => 'pay',
            starts_at        => '2020-01-01T00:00:00Z',
        } );
        $studio->insert( 'entitlement_units', { entitlement_id => $e->id, resource_id => $_->id, unit => 1 } )
            for $a, $b;
        $tx->commit;
    } qr/entitlement_units_entitlement_id_resource_id_excl/, 'seats in two occurrences are two entitlements';
    is held_by($holder), 0, 'and nothing is stored';
    is $_->free_units($studio), 10, 'no seat held in ' . $_->name for $a, $b;
};

subtest 'published coverage cannot be changed' => sub {
    my ($offer) = class_with_occurrences(1);
    ok $offer->is_published && !defined $offer->resource_id,
        'a class offer version with no resource is published';
    my $d = class_in();
    throws_ok {
        $studio->query( 'UPDATE offer_versions SET class_project_id = ? WHERE id = ?', $d, $offer->id )
    } qr/immutable once published/, 'its class cannot be changed';
    throws_ok {
        $studio->query( 'UPDATE offer_versions SET class_project_id = NULL, resource_id = ? WHERE id = ?',
            Registry::DAO::Resource->for_occurrence( $studio, event_of($d) )->id, $offer->id )
    } qr/immutable once published/, 'nor swapped for one resource';
    is( Registry::DAO::OfferVersion->find( $studio, { id => $offer->id } )->class_project_id,
        $offer->class_project_id, 'it still covers its class' );
};

subtest 'an offer version buys one resource or one class' => sub {
    my $c        = class_in();
    my $resource = Registry::DAO::Resource->for_occurrence( $studio, event_of($c) );
    my $offer    = Registry::DAO::Offer->create( $studio, { name => 'Muddled' } );
    throws_ok { $offer->draft( $studio, offer_terms( $resource->id, class_project_id => $c ) ) }
        qr/offer_versions_buys_resource_or_class/, 'not both';
    throws_ok { $offer->draft( $studio, offer_terms(undef) ) }
        qr/offer_versions_buys_resource_or_class/, 'nor neither';
};

done_testing;
