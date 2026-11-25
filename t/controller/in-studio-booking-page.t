#!/usr/bin/env perl
# ABOUTME: The in-studio-booking pages over HTTP: an anonymous visitor picks an occurrence and sees its offers to choose from.
# ABOUTME: Each offer shows its price, seats and policies in plain words, and the page links /terms; design-system classes only.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use List::Util qw( uniq );
use Mojo::File qw( path );
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( authenticate_as import_all_workflows );
use Test::Registry::Offers qw( offer_terms );
use Registry;
use Registry::DAO;
use Registry::DAO::Offer;
use Registry::DAO::Project;
use Registry::DAO::Resource;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

my $teacher = Test::Registry::Fixtures::create_user( $dao,
    { username => 'book_teacher', name => 'Book Teacher', email => 'teacher@book.test', user_type => 'staff' } );
my $room = Test::Registry::Fixtures::create_location( $db,
    { name => 'Kiln room', slug => 'kiln-room', time_zone => 'America/New_York' } );

# A class named $name with one published occurrence next week, and its seats.
sub occurrence ($name) {
    my $class = Registry::DAO::Project->create( $db,
        { name => $name, seats_per_occurrence => 6, metadata => { location_id => $room->id } } );
    my $event = $db->query( q{
        INSERT INTO events (project_id, location_id, teacher_id, time, duration, capacity, status)
        VALUES (?, ?, ?, now() + interval '7 days', 90, 6, 'published') RETURNING id
    }, $class->id, $room->id, $teacher->id )->array->[0];
    return ( $class, Registry::DAO::Resource->for_occurrence( $db, $event ) );
}

# SACP's four policies: sales final; reschedule up to 48 hours before for $10.
my %SACP = (
    refund => { kind => 'none' },
    change => { kind => 'window', window_hours => 48, fee_cents => 1000, targets => 'same_offer' },
    use    => { kind => 'optional_attendance' },
    expiry => { kind => 'end_of_occurrence' },
);

sub offer ( $class, $name, %terms ) {
    return Registry::DAO::Offer->create( $db, { name => $name } )
        ->draft( $db, offer_terms( undef, class_project_id => $class->id, policies => \%SACP, %terms ) )
        ->publish($db);
}

my $css = join '', map { path( 'public/css', $_ )->slurp } qw( theme.css app.css );

sub check_screen ( $t, $screen ) {
    my @classes = uniq map { split ' ', $_->attr('class') } $t->tx->res->dom->find('#workflow-content [class]')->each;
    is_deeply [ grep { $css !~ /\.\Q$_\E(?![\w-])/ } @classes ], [], "$screen uses design-system classes only";
}

# An anonymous visitor's client at the offer page for $seats.
sub at_offers ($seats) {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->get_ok('/in-studio-booking')->status_is(200);
    my $form = $t->tx->res->dom->at('#workflow-content form');
    ok $form, 'the occurrence screen has a form' or return $t;
    $t->post_ok( $form->attr('action') => form => { occurrence_id => $seats->id } )->status_is(302);
    my $next = $t->tx->res->headers->location;
    like $next, qr{/offer\z}, 'on to the offer page';
    $t->get_ok($next)->status_is(200);
    return $t;
}

subtest 'the booking page lists the occurrence\'s offers with price, seats and policies, and links /terms' => sub {
    my ( $class, $seats ) = occurrence('Wheel basics');
    my $one    = offer( $class, 'One seat', price_cents => 4500, per_booking_cap => 4 );
    my $couple = offer( $class, 'Couple',   price_cents => 8000, units_per_acceptance => 2, per_booking_cap => 2 );

    my $t = Test::Registry::Mojo->new('Registry');
    $t->get_ok('/in-studio-booking')->status_is(200)
        ->content_like( qr/Wheel basics/, 'an anonymous visitor sees the class' );
    check_screen( $t, 'occurrence' );
    $t->element_exists( qq{#workflow-content input[name="occurrence_id"][value="${\ $seats->id }"]},
        'its occurrence can be chosen' );

    $t = at_offers($seats);
    check_screen( $t, 'offer' );
    for my $version ( $one, $couple ) {
        $t->element_exists( qq{#workflow-content input[name="offer_version_id"][value="${\ $version->id }"]},
            'each offer can be chosen' );
    }
    $t->content_like( qr/One seat/, 'the offer names are shown' )->content_like( qr/Couple/ )
        ->content_like( qr/\$45\.00/, 'with their prices' )->content_like( qr/\$80\.00/ )
        ->content_like( qr/2 seats/, 'and seats per unit' )
        ->content_like( qr/Up to 4 per booking/, 'and the per-booking cap' )
        ->content_like( qr/Sales are final\./, 'the refund policy in plain words' )
        ->content_like( qr/Reschedule up to 48 hours before, for \$10\.00\./, 'and the change policy' );
    $t->element_exists( '#workflow-content a[href="/terms"]', 'the page links /terms' );
    $t->element_exists( '#workflow-content input[name="count"][value="1"][min="1"]', 'the count starts at 1' );
};

subtest 'a signed-in visitor holds the seats and reaches payment' => sub {
    my ( $class, $seats ) = occurrence('Glazing');
    my $version = offer( $class, 'One seat', price_cents => 3000, per_booking_cap => 2 );
    my $booker  = Test::Registry::Fixtures::create_user( $dao,
        { username => 'book_sam', name => 'Book Sam', email => 'sam@book.test', user_type => 'parent' } );
    my $t = Test::Registry::Mojo->new('Registry');
    authenticate_as( $t, $booker );
    $t->get_ok('/in-studio-booking')->status_is(200);
    $t->post_ok( $t->tx->res->dom->at('#workflow-content form')->attr('action') => form => { occurrence_id => $seats->id } )
        ->status_is(302);
    $t->get_ok( $t->tx->res->headers->location )->status_is(200);
    $t->post_ok( $t->tx->res->dom->at('#workflow-content form')->attr('action') =>
        form => { offer_version_id => $version->id, count => 2 } )->status_is(302);
    like my $account = $t->tx->res->headers->location, qr{/account\z}, 'on to the account page';
    $t->get_ok($account)->status_is(200)->content_like( qr/Signed in as Book Sam/, 'which knows who is signed in' );
    check_screen( $t, 'account' );
    $t->post_ok( $t->tx->res->dom->at('#workflow-content form')->attr('action') => form => { action => 'continue_logged_in' } )
        ->status_is(302);
    like my $hold = $t->tx->res->headers->location, qr{/hold\z}, 'on to the hold page';
    $t->get_ok($hold)->status_is(200)->content_like( qr/Total: \$60\.00/, 'which shows the total' );
    check_screen( $t, 'hold' );
    $t->post_ok( $t->tx->res->dom->at('#workflow-content form')->attr('action') => form => {} )->status_is(302);
    like my $payment = $t->tx->res->headers->location, qr{/payment\z}, 'on to payment';
    is $seats->free_units($db), 4, 'with two seats held';
    $t->get_ok($payment)->status_is(200)->content_like( qr/One seat x 2: \$60\.00/, 'which shows what is owed' );
    check_screen( $t, 'payment' );
};

done_testing;
