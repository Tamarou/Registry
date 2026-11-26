#!/usr/bin/env perl
# ABOUTME: The in-studio-day-view workflow over HTTP: one studio-local day's occurrences, seats held and bookings.
# ABOUTME: Staff and admins may mark a booker present (optional attendance); nothing else is editable.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use List::Util qw( uniq );
use Mojo::File qw( path );
use Mojo::URL;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( authenticate_as import_all_workflows join_tenant );
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO;
use Registry::DAO::Entitlement;
use Registry::DAO::Offer;
use Registry::DAO::Resource;
use Registry::PriceOps::Hold;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

my $made = 0;

sub member ( $role, $type = $role ) {
    my $n    = ++$made;
    my $user = Test::Registry::Fixtures::create_user( $dao, {
        username => "dv_${role}_$n", name => "DV \u$role $n", email => "dv_${role}_$n\@day.test",
        user_type => $type } );
    join_tenant( $dao, $user, $role );
    return $user;
}

my %user = map { $_ => member($_) } qw( admin staff parent );

# A studio location; registry's seed already has 'Online', so pages name the location.
my $floor = Test::Registry::Fixtures::create_location( $db,
    { name => 'Studio floor', slug => 'studio-floor', time_zone => 'America/New_York' } );
my $class = $db->insert( 'projects', { name => 'Wheel throwing', slug => 'wheel-throwing' },
    { returning => 'id' } )->hash->{id};
my $version = Registry::DAO::Offer->create( $db, { name => 'Couple (two seats)' } )
    ->draft( $db, offer_terms( undef, class_project_id => $class, units_per_acceptance => 2, per_booking_cap => 3,
        policies => { refund => { kind => 'none' }, use => { kind => 'optional_attendance' },
                      expiry => { kind => 'end_of_occurrence' } } ) )
    ->publish($db);

# An occurrence of the class at $local (wall clock at $location) with $capacity seats.
sub occurrence ( $local, $capacity = 8, $location = $floor ) {
    my $event = $db->insert( 'events', {
        project_id => $class, location_id => $location->id, teacher_id => $user{staff}->id,
        time       => \[ '?::timestamp AT TIME ZONE ?', $local, $location->time_zone ],
        duration   => 90, capacity => $capacity, status => 'published',
    }, { returning => 'id' } )->hash->{id};
    return Registry::DAO::Resource->for_occurrence( $db, $event );
}

# $holder's booking of $count couples in $resource.
sub booking ( $resource, $holder, $count = 1 ) {
    my ( undef, $ends ) = $resource->occurrence_window($db);
    return Registry::DAO::Entitlement->grant( $db, {
        holder_user_id   => $holder->id,
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
        starts_at        => '2020-01-01T00:00:00Z',
        ends_at          => $ends,
        resource_id      => $resource->id,
        units            => $version->seats_for($count),
    } );
}

sub run_id () {
    my $w = $db->select( 'workflows', 'id', { slug => 'in-studio-booking' } )->array->[0];
    return $db->insert( 'workflow_runs', { workflow_id => $w }, { returning => 'id' } )->hash->{id};
}

# A live hold of $units seats in $resource.
sub hold ( $resource, $units ) {
    return Registry::PriceOps::Hold->place( $db, {
        resource_id => $resource->id, units => $units, workflow_run_id => run_id(),
        expires_at  => \"clock_timestamp() + interval '15 minutes'",
    } );
}

# A client with its own session, signed in as $user (none for anonymous).
sub client ( $user = undef ) {
    my $t = Test::Registry::Mojo->new('Registry');
    authenticate_as( $t, $user ) if $user;
    return $t;
}

my $css = join '', map { path( 'public/css', $_ )->slurp } qw( theme.css app.css );

sub check_screen ( $t, $screen ) {
    my @classes = uniq map { split ' ', $_->attr('class') } $t->tx->res->dom->find('#workflow-content [class]')->each;
    is_deeply [ grep { $css !~ /\.\Q$_\E(?![\w-])/ } @classes ], [], "$screen uses design-system classes only";
}

# The occurrence ids a day view lists, in the order it lists them.
sub listed ($t) {
    return [ map { $_->attr('data-occurrence') } $t->tx->res->dom->find('[data-occurrence]')->each ];
}

sub day_url ( $day, $location = $floor ) {
    return Mojo::URL->new('/in-studio-day-view')->query( location_id => $location->id, day => $day );
}

sub section ( $t, $resource ) {
    return $t->tx->res->dom->at(qq{[data-occurrence="${\ $resource->id }"]});
}

subtest 'staff see a local day\'s occurrences with seats held and bookings' => sub {
    my $late  = occurrence('2027-04-14 18:00');
    my $early = occurrence( '2027-04-14 09:30', 6 );
    my $next  = occurrence('2027-04-15 09:30');
    my $sam   = member('parent');
    my $e     = booking( $early, $sam, 2 );
    hold( $early, 1 );

    my $t = client( $user{staff} );
    $t->get_ok( day_url( '2027-04-14' ) )->status_is(200);
    check_screen( $t, 'day view' );
    is_deeply listed($t), [ $early->id, $late->id ], 'that day\'s occurrences in local start order, no other day\'s';
    my $card = section( $t, $early ) or return fail 'the early occurrence is listed';
    like $card->all_text, qr/09:30/, 'with its local start';
    like $card->all_text, qr/Wheel throwing/, 'its class';
    like $card->all_text, qr/Capacity 6\b/, 'its capacity';
    like $card->all_text, qr/Seats held 5\b/, 'seats held: four booked and one on hold';
    my $row = $card->at(qq{[data-entitlement="${\ $e->id }"]}) or return fail 'the booking is listed';
    like $row->all_text, qr/DV Parent/, 'with its booker';
    like $row->all_text, qr/\b2 booked\b/, 'the count booked';
    like $row->all_text, qr/\b4 seats\b/, 'and the seats';
    ok $row->at(qq{a[href\$="/entitlement-change?entitlement_id=${\ $e->id }"]}), 'staff can reschedule it from here';
    like section( $t, $late )->all_text, qr/Seats held 0\b/, 'an empty occurrence holds nothing';

    my $today = $db->query(q{SELECT to_char(now() AT TIME ZONE 'America/New_York', 'YYYY-MM-DD')})->array->[0];
    client( $user{admin} )->get_ok( day_url('') )->status_is(200)
        ->element_exists( qq{#workflow-content input[name="day"][value="$today"]},
            'an admin sees it too, defaulting to today in the studio\'s zone' );
    client( $user{staff} )->get_ok('/in-studio-day-view')->status_is(200)
        ->element_exists( qq{#workflow-content select[name="location_id"] option[value="${\ $floor->id }"]},
            'with several locations and none chosen, it asks which' )
        ->element_exists_not( '[data-occurrence]', 'and lists nothing yet' );
};

done_testing;
