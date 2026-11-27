#!/usr/bin/env perl
# ABOUTME: session-setup publishes prices over a program's sessions over HTTP: a regular, a sibling and an early-bird version.
# ABOUTME: Early-bird is read in the location's zone and stored as an instant; a version with no session chosen is refused.
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
use Registry::DAO::Offer;
use Registry::DAO::Resource;
use Registry::DAO::WorkflowRun;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

my %user;
for my $role (qw( admin staff )) {
    $user{$role} = Test::Registry::Fixtures::create_user( $dao,
        { username => "publish_$role", name => "Publish \u$role", email => "$role\@publish.test", user_type => $role } );
    join_tenant( $dao, $user{$role}, $role );
}
my $site = Test::Registry::Fixtures::create_location( $db,
    { name => 'Camp lake', slug => 'camp-lake', time_zone => 'America/New_York' } );

my $t = Test::Registry::Mojo->new('Registry');
authenticate_as( $t, $user{admin} );

my $css = join '', map { path( 'public/css', $_ )->slurp } qw( theme.css app.css );

sub check_screen ($screen) {
    my @classes = uniq map { split ' ', $_->attr('class') } $t->tx->res->dom->find('#workflow-content [class]')->each;
    is_deeply [ grep { $css !~ /\.\Q$_\E(?![\w-])/ } @classes ], [], "$screen uses design-system classes only";
}

# Posts %fields through the page's form, each of which it must offer, and
# follows the redirect or reads the page it stays on. Returns the URL shown.
sub submit_step ( $screen, %fields ) {
    my $form = $t->tx->res->dom->at('#workflow-content form');
    ok $form, "$screen has a form" or return '';
    ok $form->at(qq{[name="$_"]}), "$screen asks for $_" for sort keys %fields;
    my $action = $form->attr('action');
    $t->post_ok( $action => form => \%fields );
    my $shown = $action;
    if ( $t->tx->res->code == 302 ) {
        $shown = $t->tx->res->headers->location;
        $t->get_ok($shown);
    }
    $t->status_is(200);
    check_screen($screen);
    return $shown;
}

my %WEEK = (
    first_day => '2027-06-07', last_day => '2027-06-11', weekdays => [ 1 .. 5 ], start => '09:00', minutes => 420,
    capacity  => 12, waitlist => 'none', action => 'add',
);

my @sessions;

# From the offer-basics screen of a run, the rest of a version's steps to its complete page.
sub publish_version ( $name, $cents, %conditions ) {
    like submit_step( 'offer-basics', resource_ids => [ map { $_->id } @sessions ], offer_name => $name ),
        qr{/offer-price\z}, "$name covers both sessions";
    like submit_step( 'offer-price', price_cents => $cents, currency => 'USD', units_per_acceptance => 1, per_booking_cap => 1 ),
        qr{/conditions\z}, 'then who may choose it';
    like submit_step( 'conditions', %conditions ), qr{/one-time-payment\z}, 'then how it is paid';
    like submit_step( 'one-time-payment', one_time => 'offered' ), qr{/instalment-payment\z}, 'once';
    like submit_step( 'instalment-payment', instalments => 'declined' ), qr{/refund-policy\z}, 'or not in instalments';
    like submit_step( 'refund-policy', refund => 'full_until_cutoff', cutoff_hours => 72, approval => 'required' ),
        qr{/change-policy\z}, 'a refund cutoff counted from the first day';
    like submit_step( 'change-policy', change => 'window', window_hours => 48, fee_cents => 0, targets => 'same_program',
        price_difference => 'charge_and_refund', approval => 'required' ), qr{/use-policy\z}, 'a change within the program';
    like submit_step( 'use-policy', use => 'optional_attendance' ), qr{/expiry-policy\z}, 'use';
    like submit_step( 'expiry-policy', expiry => 'end_of_occurrence' ), qr{/publish\z}, 'expiry';
    $t->content_like( qr/Week 1/, 'the review names the sessions' );
    like submit_step( 'publish', action => 'publish' ), qr{/complete\z}, "$name is published";
    $t->content_like( qr/\Q$name\E is published/ );
}

# From the complete page, a new run for the same program goes past its sessions.
sub another_price () {
    my %hidden = map { $_->attr('name') => $_->val } $t->tx->res->dom->find('#workflow-content form input[type="hidden"]')->each;
    like submit_step( 'complete', %hidden ), qr{/sessions\z}, 'another price starts a run on the same program';
    like submit_step( 'sessions', action => 'continue' ), qr{/offer-basics\z}, 'whose sessions are already there';
    $t->content_like( qr/Week 1/ )->content_like( qr/Week 2/, 'offer-basics lists the program\'s sessions' );
}

sub current ($name) {
    my ($offer) = Registry::DAO::Offer->find( $db, { name => $name } );
    return $offer && $offer->current_version($db);
}

subtest 'three versions publish over two sessions' => sub {
    $t->get_ok('/session-setup')->status_is(200);
    like submit_step( 'program', program_mode => 'create', program_name => 'Lake camp', location_id => $site->id ),
        qr{/sessions\z}, 'on to the sessions';
    for my $n ( 1, 2 ) {
        submit_step( 'sessions', %WEEK, name => "Week $n", teacher_id => $user{staff}->id,
            first_day => sprintf( '2027-06-%02d', 7 * $n ), last_day => sprintf( '2027-06-%02d', 7 * $n + 4 ) );
    }
    @sessions = map { Registry::DAO::Resource->find( $db, { name => $_ } ) } 'Week 1', 'Week 2';
    is scalar @sessions, 2, 'two sessions';
    like submit_step( 'sessions', action => 'continue' ), qr{/offer-basics\z}, 'on to the first price';

    publish_version( 'Camp', 30000, sibling => 'none' );
    another_price();
    publish_version( 'Camp sibling', 27000, sibling => 'any' );
    another_price();
    publish_version( 'Camp early bird', 25000, sibling => 'none', early_bird_until => '2027-03-01T00:00' );

    my @ids = sort map { $_->id } @sessions;
    for ( [ 'Camp', 30000 ], [ 'Camp sibling', 27000 ], [ 'Camp early bird', 25000 ] ) {
        my ( $name, $cents ) = @$_;
        my $version = current($name);
        ok $version, "$name has a current version" or next;
        is $version->price_cents, $cents, "$name costs $cents cents";
        is_deeply [ sort map { $_->id } $version->covered_resources($db)->@* ], \@ids, "$name covers the two sessions";
        is_deeply $version->policies->{refund}, { kind => 'full_until_cutoff', cutoff_hours => 72, approval => 'required' },
            "$name keeps the refund cutoff";
        is $version->policies->{change}{targets}, 'same_program', "$name moves within the program";
    }
    is_deeply current('Camp')->conditions, [], 'Camp has no condition';
    is_deeply current('Camp sibling')->conditions, [ { kind => 'family_holds_entitlement' } ],
        'Camp sibling is for a family already holding a place';
};

subtest 'early bird until is stored as an instant' => sub {
    is_deeply current('Camp early bird')->conditions, [ { kind => 'before', at => '2027-03-01T05:00:00Z' } ],
        'midnight in New York on 2027-03-01 is 05:00 UTC';
};

done_testing;
