#!/usr/bin/env perl
# ABOUTME: The in-studio class setup screens over HTTP: an admin defines a class and publishes its offer.
# ABOUTME: Design-system classes only; the complete page starts another offer for the same class; staff are refused.
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
use Test::Registry::Helpers qw( authenticate_as import_all_workflows join_tenant );
use Registry;
use Registry::DAO;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

my %user;
for my $role (qw( admin staff )) {
    $user{$role} = Test::Registry::Fixtures::create_user( $dao,
        { username => "class_$role", name => "Class \u$role", email => "$role\@class.test", user_type => $role } );
    join_tenant( $dao, $user{$role}, $role );
}
my $room = Test::Registry::Fixtures::create_location( $db, { name => 'Glaze room', slug => 'glaze-room' } );

sub client ($user) {
    my $t = Test::Registry::Mojo->new('Registry');
    authenticate_as( $t, $user );
    return $t;
}

my $css = join '', map { path( 'public/css', $_ )->slurp } qw( theme.css app.css );

sub check_screen ( $t, $screen ) {
    my @classes = uniq map { split ' ', $_->attr('class') } $t->tx->res->dom->find('#workflow-content [class]')->each;
    is_deeply [ grep { $css !~ /\.\Q$_\E(?![\w-])/ } @classes ], [], "$screen uses design-system classes only";
}

# Submits the page's form with %fields, each of which it must offer, and
# follows the redirect. Returns the next screen's URL.
sub submit_step ( $t, $screen, %fields ) {
    my $form = $t->tx->res->dom->at('#workflow-content form');
    ok $form, "$screen has a form" or return '';
    ok $form->at(qq{[name="$_"]}), "$screen asks for $_" for sort keys %fields;
    $t->post_ok( $form->attr('action') => form => \%fields )->status_is(302);
    my $next = $t->tx->res->headers->location;
    $t->get_ok($next)->status_is(200);
    check_screen( $t, $next );
    return $next;
}

my @OFFER_STEPS = (
    [ 'offer-price'      => price_cents => 4500, currency => 'USD', units_per_acceptance => 1, per_booking_cap => 4 ],
    [ 'one-time-payment' => one_time => 'offered' ],
    [ 'refund-policy'    => refund => 'none' ],
    [ 'change-policy'    => change => 'window', window_hours => 48, fee_cents => 1000, targets => 'same_offer' ],
    [ 'use-policy'       => use => 'optional_attendance' ],
    [ 'expiry-policy'    => expiry => 'end_of_occurrence' ],
    [ 'publish'          => action => 'publish' ],
);

subtest 'admin sets up a class and publishes its offer over http' => sub {
    my $t = client( $user{admin} );
    $t->get_ok('/in-studio-class-setup')->status_is(200);
    check_screen( $t, 'class' );
    $t->element_exists( qq{#workflow-content select[name="location_id"] option[value="${\ $room->id}"]},
        'the class screen offers this tenant\'s locations' );
    like submit_step( $t, 'class', class_mode => 'create', class_name => 'Glazing', location_id => $room->id,
        seats_per_occurrence => 6 ), qr{/offer-basics\z}, 'on to the offer';
    $t->content_like(qr/Glazing/, 'the offer screen names the class');
    my $next = submit_step( $t, 'offer-basics', offer_name => 'One seat' );
    like $next, qr{/offer-price\z}, 'on to the price';
    $next = submit_step( $t, @$_ ) for @OFFER_STEPS;
    like $next, qr{/complete\z}, 'publishing lands on the complete page';
    $t->content_like(qr/One seat is published/);

    my $class = $db->query(q{SELECT id FROM projects WHERE name = 'Glazing'})->hash->{id};
    $t->element_exists( '#workflow-content a[href$="/in-studio-schedule"]', 'the complete page links scheduling occurrences' );
    is $t->tx->res->dom->at('#workflow-content input[name="class_project_id"]')->val, $class,
        'the complete page carries the class into another offer';
    like submit_step( $t, 'complete', class_mode => 'existing', class_project_id => $class ), qr{/offer-basics\z},
        'and starts another offer for this class on the offer step';
    $t->element_exists( '#workflow-content input[name="offer_name"]', 'a new run, already past the class step' )
        ->content_like(qr/Glazing/);
    submit_step( $t, 'offer-basics', offer_name => 'Couple (two seats)' );
    submit_step( $t, @{ [ $OFFER_STEPS[0]->@*, units_per_acceptance => 2 ] } );
    submit_step( $t, @$_ ) for @OFFER_STEPS[ 1 .. $#OFFER_STEPS ];
    is $db->query( q{SELECT count(*) FROM offer_versions WHERE class_project_id = ? AND published_at IS NOT NULL}, $class )
        ->array->[0], 2, 'two offers now cover the class';
};

subtest 'staff are refused at the route' => sub {
    client( $user{staff} )->get_ok('/in-studio-class-setup')->status_is(403);
};

done_testing;
