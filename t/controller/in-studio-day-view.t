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
use Registry::DAO::Tenant;
use Registry::DAO::WorkflowRun;
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
sub booking ( $resource, $holder, $count = 1, $sold = $version ) {
    my ( undef, $ends ) = $resource->occurrence_window($db);
    return Registry::DAO::Entitlement->grant( $db, {
        holder_user_id   => $holder->id,
        offer_version_id => $sold->id,
        payment_plan_id  => 'pay',
        starts_at        => '2020-01-01T00:00:00Z',
        ends_at          => $ends,
        resource_id      => $resource->id,
        units            => $sold->seats_for($count),
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
    my $re = $row->at('form[action$="/entitlement-change"]');
    ok $re && $re->at(qq{input[name="entitlement_id"][value="${\ $e->id }"]}), 'staff can reschedule it from here';
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

sub hidden ($form) {
    return map { $_->attr('name') => $_->attr('value') } $form->find('input[type="hidden"]')->each;
}

sub uses ($e) {
    return $db->select( 'entitlement_uses', '*', { entitlement_id => $e->id } )->hashes->to_array;
}

subtest 'an occurrence at 23:30 local, the next day in UTC, is on its local day' => sub {
    my $late = occurrence('2027-05-10 23:30');
    my $t    = client( $user{staff} );
    $t->get_ok( day_url('2027-05-10') )->status_is(200);
    is_deeply listed($t), [ $late->id ], 'listed on its local day';
    my $card = section( $t, $late ) or return fail q{it is listed};
    like $card->all_text, qr/23:30/, 'at its local start';
    $t->get_ok( day_url('2027-05-11') )->status_is(200);
    is_deeply listed($t), [], 'not on the UTC day it falls in';
};

subtest 'marking attendance records it' => sub {
    my $o = occurrence('2027-05-20 10:00');
    my $e = booking( $o, member('parent') );
    my $t = client( $user{staff} );
    $t->get_ok( day_url('2027-05-20') )->status_is(200);
    my $form = section( $t, $o )->at(qq{[data-entitlement="${\ $e->id }"] form}) or return fail 'a present mark';
    my %fields = hidden($form);
    $t->post_ok( $form->attr('action') => form => \%fields )->status_is(302);
    my $back = Mojo::URL->new( $t->tx->res->headers->location );
    is $back->path, '/in-studio-day-view', 'back to the day view';
    is $back->query->param('day'), '2027-05-20', 'on the same day';
    my $uses = uses($e);
    is scalar @$uses, 1, 'one use is recorded';
    is $uses->[0]{occurrence_id}, $o->id, 'for that occurrence';
    is $uses->[0]{recorded_by}, $user{staff}->id, 'by the staff member who marked it';
    $t->get_ok($back)->status_is(200);
    like section( $t, $o )->at(qq{[data-entitlement="${\ $e->id }"]})->all_text, qr/Present/, 'the booking shows present';
    is section( $t, $o )->at(qq{[data-entitlement="${\ $e->id }"] input[name="occurrence_id"]}), undef, 'with no mark left to make';
};

subtest 'a customer is refused' => sub {
    my $o = occurrence('2027-05-21 10:00');
    my $e = booking( $o, $user{parent} );
    my $t = client( $user{parent} );
    $t->get_ok( day_url('2027-05-21') )->status_is(403)->content_unlike(qr/DV Parent/, 'and sees no booking');
    my $staff = client( $user{staff} );
    $staff->get_ok( day_url('2027-05-21') )->status_is(200);
    my $action = section( $staff, $o )->at('form')->attr('action');
    $t->post_ok( $action => form => { entitlement_id => $e->id, occurrence_id => $o->id } )
        ->status_is( 403, 'nor may they mark themselves present' );
    is_deeply uses($e), [], 'and nothing is recorded';
};

# Tenant B: its own schema, with $staff as its staff member and a booking of
# its own in an occurrence of its own. Returns B's handle and that booking.
sub other_tenant ($staff) {
    my $slug = 'dv_other_' . ++$made;
    Registry::DAO::Tenant->provision( $db, { name => "DV Other $made", slug => $slug, users => [] } );
    join_tenant( $dao, $staff, 'staff', $slug );
    my $b     = $dao->connect_schema($slug)->db;
    my $room  = $b->insert( 'locations', { time_zone => 'America/New_York', name => 'Far room', slug => 'far-room' },
        { returning => 'id' } )->hash->{id};
    my $class = $b->insert( 'projects', { name => 'Far class', slug => 'far-class' }, { returning => 'id' } )->hash->{id};
    my $who   = $b->insert( 'users', { username => "dv-far-$made" }, { returning => 'id' } )->hash->{id};
    my $res   = Registry::DAO::Resource->for_occurrence( $b, $b->insert( 'events', {
        project_id => $class, location_id => $room, teacher_id => $who,
        time => '2027-07-01T14:00:00Z', duration => 90, capacity => 4 }, { returning => 'id' } )->hash->{id} );
    my $v = Registry::DAO::Offer->create( $b, { name => 'Far wheel' } )
        ->draft( $b, offer_terms( undef, class_project_id => $class,
            policies => { refund => { kind => 'none' }, use => { kind => 'optional_attendance' } } ) )->publish($b);
    my $e = Registry::DAO::Entitlement->grant( $b, {
        holder_user_id => $who, offer_version_id => $v->id, payment_plan_id => 'pay',
        starts_at => '2020-01-01T00:00:00Z', ends_at => '2027-07-01T15:30:00Z', resource_id => $res->id, units => 1 } );
    return ( $b, $e );
}

subtest 'anonymous visitor refused' => sub {
    my $o = occurrence('2027-06-10 10:00');
    my $e = booking( $o, member('parent') );
    my $t = client();
    $t->get_ok( day_url('2027-06-10') )->status_is(302)->header_is( Location => '/auth/login', 'sent to log in' )
        ->content_unlike( qr/DV Parent/, 'and shown no booking' );
    $t->post_ok( '/in-studio-day-view' => form => { entitlement_id => $e->id, occurrence_id => $o->id } )
        ->status_is(302)->header_is( Location => '/auth/login', 'a POST is sent to log in too' );
    is_deeply uses($e), [], 'and nothing is recorded';
};

subtest 'staff of another tenant refused' => sub {
    my $o        = occurrence('2027-06-11 10:00');
    my $e        = booking( $o, member('parent') );
    my $stranger = Test::Registry::Fixtures::create_user( $dao, {
        username => 'dv_far_staff', name => 'Far Staff', email => 'far@day.test', user_type => 'staff' } );
    other_tenant($stranger);
    my $t = client($stranger);
    $t->get_ok( day_url('2027-06-11') )->status_is( 403, 'tenant B\'s staff are refused on tenant A\'s host' )
        ->content_unlike( qr/DV Parent/, 'and shown no booking' );
    my $staff = client( $user{staff} );
    $staff->get_ok( day_url('2027-06-11') )->status_is(200);
    $t->post_ok( section( $staff, $o )->at('form')->attr('action') =>
        form => { entitlement_id => $e->id, occurrence_id => $o->id } )->status_is( 403, 'nor may they mark it' );
    is_deeply uses($e), [], 'and nothing is recorded';
};

subtest 'malformed day parameter is a 400' => sub {
    my $t = client( $user{staff} );
    for my $day ( '2027-02-30', '0000-02-15', 'yesterday', q{2027-01-01'; DROP TABLE events; --}, '27-1-1' ) {
        $t->get_ok( day_url($day) )->status_is( 400, "'$day' is a 400" )
            ->content_like( qr/Give the day as a real date, YYYY-MM-DD/, 'with a message' )
            ->element_exists_not( '[data-occurrence]', 'and no occurrence' );
    }
    $t->get_ok('/in-studio-day-view?day=2027-06-01&day=2027-06-02')->status_is( 400, 'two days are a 400' );
    $t->get_ok( Mojo::URL->new('/in-studio-day-view')->query( location_id => 'nowhere', day => '2027-06-01' ) )
        ->status_is( 400, 'an unknown location is a 400' )->content_like(qr/Choose one of the listed locations/);
    ok $db->query(q{SELECT to_regclass('events')})->array->[0], 'events survives';
};

subtest 'attendance on foreign booking refused' => sub {
    my $o     = occurrence('2027-06-12 10:00');
    my $there = occurrence('2027-06-12 12:00');
    my $mine  = booking( $o, member('parent') );
    my $elsewhere = booking( $there, member('parent') );
    my $t = client( $user{staff} );
    $t->get_ok( day_url('2027-06-12') )->status_is(200);
    my $action = section( $t, $o )->at('form')->attr('action');

    my %shown = ( day => '2027-06-12', location_id => $floor->id );
    $t->post_ok( $action => form => { %shown, entitlement_id => $elsewhere->id, occurrence_id => $o->id } )
        ->status_is(200)->content_like( qr/holds no place in that occurrence/,
        'a booking not in that occurrence is refused with a message' );
    is_deeply listed($t), [ $o->id, $there->id ], 'back on the same day and location';
    $t->element_exists( '#workflow-content input[name="day"][value="2027-06-12"]', 'with that day chosen' );
    is_deeply uses($elsewhere), [], 'and nothing is recorded';

    my ( $b, $far ) = other_tenant( member('staff') );
    $t->post_ok( $action => form => { %shown, entitlement_id => $far->id, occurrence_id => $o->id } )
        ->status_is(200)->content_like( qr/That booking was not found/,
        'another tenant\'s booking is not found' );
    is $b->select( 'entitlement_uses', 'count(*)', { entitlement_id => $far->id } )->array->[0], 0,
        'nothing is recorded in its tenant';
    is $db->select( 'entitlement_uses', 'count(*)', { entitlement_id => $far->id } )->array->[0], 0, 'nor in this one';
    is_deeply uses($mine), [], 'nor against this occurrence\'s own booking';
};

subtest 'ended bookings and expired holds not shown as held' => sub {
    my $o       = occurrence( '2027-06-13 10:00', 10 );
    my $kept    = booking( $o, member('parent') );
    my $ended   = booking( $o, member('parent'), 2 );
    $ended->end( $db, 'refunded', 'refunded in full' );
    my $lapsed  = hold( $o, 3 );
    $db->update( 'holds', { expires_at => \"clock_timestamp() - interval '1 minute'" }, { id => $lapsed->id } );
    my $released = hold( $o, 1 );
    $db->update( 'holds', { state => 'released' }, { id => $released->id } );

    my $t = client( $user{staff} );
    $t->get_ok( day_url('2027-06-13') )->status_is(200);
    my $card = section( $t, $o );
    like $card->all_text, qr/Seats held 2\b/, 'only the active booking\'s two seats are held';
    ok $card->at(qq{[data-entitlement="${\ $kept->id }"]}), 'it is listed';
    is $card->at(qq{[data-entitlement="${\ $ended->id }"]}), undef, 'the ended one is not';
};

subtest 'early morning local occurrence on its local day' => sub {
    my $tokyo = Test::Registry::Fixtures::create_location( $db,
        { name => 'Tokyo annex', slug => 'tokyo-annex', time_zone => 'Asia/Tokyo' } );
    my $o = occurrence( '2027-06-02 00:30', 8, $tokyo );
    is $db->query( q{SELECT to_char(time AT TIME ZONE 'UTC', 'YYYY-MM-DD') FROM events WHERE id = ?}, $o->event_id )
        ->array->[0], '2027-06-01', 'it is the previous day in UTC';
    my $t = client( $user{staff} );
    $t->get_ok( day_url( '2027-06-02', $tokyo ) )->status_is(200);
    is_deeply listed($t), [ $o->id ], 'listed on its local day';
    my $card = section( $t, $o ) or return fail q{it is listed};
    like $card->all_text, qr/00:30/, 'at its local start';
    $t->get_ok( day_url( '2027-06-01', $tokyo ) )->status_is(200);
    is_deeply listed($t), [], 'and not on the UTC day';
};

subtest 'marking present for an occurrence not on the shown day refused' => sub {
    my $shown = occurrence('2027-06-14 10:00');
    my $other = occurrence('2027-06-15 10:00');
    my $e     = booking( $other, member('parent') );
    booking( $shown, member('parent') );
    my $back  = Test::Registry::Fixtures::create_location( $db,
        { name => 'Back room', slug => 'back-room', time_zone => 'America/New_York' } );
    my $t = client( $user{staff} );
    $t->get_ok( day_url('2027-06-14') )->status_is(200);
    my $action = section( $t, $shown )->at('form')->attr('action');
    my %mark   = ( entitlement_id => $e->id, occurrence_id => $other->id );
    $t->post_ok( $action => form => { %mark, day => '2027-06-14', location_id => $floor->id } )
        ->status_is(200)->content_like( qr/That class is not on the day shown here/, 'a class on another day is refused' );
    $t->post_ok( $action => form => { %mark, day => '2027-06-15', location_id => $back->id } )
        ->status_is(200)->content_like( qr/That class is not on the day shown here/, 'and one at another location' );
    is_deeply uses($e), [], 'and nothing is recorded';
    $t->post_ok( $action => form => { %mark, day => '2027-06-15', location_id => $floor->id } )->status_is(302);
    is scalar uses($e)->@*, 1, 'on its own day and location it is recorded';
};

# A published version of a new offer for the class that may be changed up to
# 48 hours before, for $fee cents, to another occurrence of the same offer.
sub changeable ($fee) {
    return Registry::DAO::Offer->create( $db, { name => 'Changeable ' . ++$made } )
        ->draft( $db, offer_terms( undef, class_project_id => $class, policies => {
            refund => { kind => 'none' }, use => { kind => 'optional_attendance' },
            change => { kind => 'window', window_hours => 48, fee_cents => $fee, targets => 'same_offer' },
            expiry => { kind => 'end_of_occurrence' } } ) )
        ->publish($db);
}

subtest 'reschedule from the day view starts a change for exactly that booking' => sub {
    my $v  = changeable(0);
    my $o  = occurrence('2027-06-20 10:00');
    my $to = occurrence('2027-06-27 10:00');
    my $y  = booking( $o, member('parent'), 1, $v );
    my $z  = booking( $o, member('parent'), 1, $v );
    my $t  = client( $user{staff} );
    # Follows $e's Reschedule control on the day view; returns the change run it lands in.
    my $reschedule = sub ($e) {
        $t->get_ok( day_url('2027-06-20') )->status_is(200);
        my $row = section( $t, $o )->at(qq{[data-entitlement="${\ $e->id }"]}) or return fail 'the booking is listed';
        if ( my $form = $row->at('form[action*="entitlement-change"]') ) {
            $t->post_ok( $form->attr('action') => form => { hidden($form) } )->status_is(302);
            $t->get_ok( $t->tx->res->headers->location )->status_is(200);
        }
        else {
            $t->get_ok( $row->at('a[href*="entitlement-change"]')->attr('href') )->status_is(200);
        }
        my ($id) = ( $t->tx->res->dom->at('#workflow-content form') // return fail 'a change form' )->attr('action')
            =~ m{/entitlement-change/([0-9a-f-]{36})/};
        return Registry::DAO::WorkflowRun->find( $db, { id => $id } );
    };
    my $first = $reschedule->($y) or return;
    is $first->data->{change_entitlement_id}, $y->id, 'the first reschedule changes Y';
    my $second = $reschedule->($z) or return;    # Y's change is abandoned
    is $second->data->{change_entitlement_id}, $z->id, 'the second changes Z, not the abandoned Y';

    my $form = $t->tx->res->dom->at('#workflow-content form');
    $t->post_ok( $form->attr('action') => form => { target_occurrence_id => $to->id } )->status_is(302);
    like my $next = $t->tx->res->headers->location, qr{/complete-change\z}, 'a $0 change needs no payment';
    $t->get_ok($next)->status_is(200);
    $t->post_ok( $t->tx->res->dom->at('#workflow-content form')->attr('action') => form => {} )->status_is(302);
    is_deeply $z->units( $db, $to->id ), [1], 'Z moves to the target';
    is_deeply $y->units( $db, $o->id ), [1], 'and Y stays where it was';
};

done_testing;
