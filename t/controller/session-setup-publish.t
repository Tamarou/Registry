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
use Registry::DAO::Project;
use Registry::DAO::Resource;
use Registry::DAO::WorkflowSteps::RefundPolicy;
use Registry::DAO::WorkflowRun;

# Many screens from one client in a minute: lift the per-IP limit, as
# signup-lists-platform-offers.t does.
$Registry::Middleware::RateLimit::GENERAL_LIMIT = $Registry::Middleware::RateLimit::AUTH_LIMIT = 10_000;

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
    $t->element_exists_not( '#workflow-content input[name="expiry"][value="never"]', 'never is not offered over sessions' );
    like submit_step( 'expiry-policy', expiry => 'end_of_occurrence' ), qr{/publish\z}, 'expiry';
    $t->content_like( qr/Week 1/, 'the review names the sessions' );
    if ( my $local = $conditions{early_bird_until} ) {
        $local =~ s/T/ /;
        $t->content_like( qr/Only until \Q$local\E in the location&#39;s time/, 'the review shows the early bird in local time' );
    }
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

# The run the client is on, read from its URL.
sub this_run () {
    my ($id) = $t->tx->req->url->path =~ m{/([0-9a-f-]{36})/};
    return scalar Registry::DAO::WorkflowRun->find( $db, { id => $id } );
}

# A new run on Lake camp, to its conditions step, for a price named $name.
sub to_conditions ($name) {
    my ($program) = Registry::DAO::Project->find( $db, { name => 'Lake camp' } );
    $t->get_ok('/session-setup')->status_is(200);
    like submit_step( 'program', program_mode => 'existing', project_id => $program->id, location_id => $site->id ),
        qr{/sessions\z}, 'a run on Lake camp';
    like submit_step( 'sessions', action => 'continue' ), qr{/offer-basics\z}, 'past its sessions';
    like submit_step( 'offer-basics', resource_ids => [ map { $_->id } @sessions ], offer_name => $name ), qr{/offer-price\z};
    like submit_step( 'offer-price', price_cents => 20000, currency => 'USD', units_per_acceptance => 1, per_booking_cap => 1 ),
        qr{/conditions\z}, "$name is at its conditions";
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

subtest 'a version with no sessions chosen is refused' => sub {
    another_price();
    like submit_step( 'offer-basics', offer_name => 'Camp nothing' ), qr{/offer-basics\z}, 'the step stays';
    $t->content_like( qr/Choose at least one of the program&#39;s sessions/, 'and says why' );

    # Publish asks again, so a run whose sessions were dropped since cannot publish.
    my ($run) = Registry::DAO::WorkflowRun->find( $db, { id => ( $t->tx->req->url->path =~ m{/([0-9a-f-]{36})/} )[0] } );
    ok $run, 'the run';
    my $publish = $dao->find( Workflow => { slug => 'session-setup' } )->get_step( $db, { slug => 'publish' } );
    $run->update_data( $db, {
        offer_basics  => { resource_ids => [], offer_name => 'Camp nothing' },
        offer_price   => { price_cents => 100, currency => 'usd', units_per_acceptance => 1, per_booking_cap => 1 },
        one_time_payment => { one_time => 'offered' },
        refund_policy => { kind => 'none', approval => 'none' },
        change_policy => { kind => 'none' },
        use_policy    => { use => 'none' },
        expiry_policy => { expiry => 'end_of_occurrence' },
    } );
    my $result = $publish->process( $db, { action => 'publish' }, $run );
    like join( ' ', ( $result->{errors} // [] )->@* ), qr/Choose at least one of the program's sessions/, 'publish refuses it too';
    ok !Registry::DAO::Offer->find( $db, { name => 'Camp nothing' } ), 'and no offer is made';
};

subtest 'an early bird in the fall-back hour is its earlier instant' => sub {
    to_conditions('Camp fall back');
    like submit_step( 'conditions', sibling => 'none', early_bird_until => '2027-11-07T01:30' ), qr{/one-time-payment\z};
    is_deeply this_run()->data->{conditions}, [ { kind => 'before', at => '2027-11-07T05:30:00Z' } ],
        '01:30 on 2027-11-07 in New York is first 01:30 EDT, 05:30 UTC';
};

subtest 'an early bird in the spring-forward gap is shown as moved' => sub {
    to_conditions('Camp spring');
    like submit_step( 'conditions', sibling => 'none', early_bird_until => '2027-03-14T02:30' ), qr{/conditions\z},
        'the step stays to show the move';
    $t->content_like( qr/2027-03-14 02:30 does not exist .* it ends at 2027-03-14 03:30/s, 'the moved time is shown' );
    is_deeply this_run()->data->{conditions}, [ { kind => 'before', at => '2027-03-14T07:30:00Z' } ], 'and recorded';
    $t->element_exists( '#workflow-content input[name="early_bird_until"][value="2027-03-14T03:30"]', 'and refilled' );
    like submit_step( 'conditions', sibling => 'none', early_bird_until => '2027-03-14T03:30' ), qr{/one-time-payment\z},
        'continuing with it goes on';
};

# A new run on Lake camp, at its offer step, posting %fields; it must stay
# there with $error.
sub offer_refused ( $error, %fields ) {
    my ($program) = Registry::DAO::Project->find( $db, { name => 'Lake camp' } );
    $t->get_ok('/session-setup')->status_is(200);
    submit_step( 'program', program_mode => 'existing', project_id => $program->id, location_id => $site->id );
    like submit_step( 'sessions', action => 'continue' ), qr{/offer-basics\z}, 'a run at its offer step';
    like submit_step( 'offer-basics', %fields ), qr{/offer-basics\z}, 'the step stays';
    $t->content_like( $error, 'and says why' );
}

# A session of its own program at $location taught by $teacher, made with the DAO in $tenant_db.
sub foreign_session ( $tenant_db, $name, $location, $teacher ) {
    my $program = Test::Registry::Fixtures::create_project( $tenant_db, { name => "$name program" } );
    return Registry::DAO::Resource->create_session( $tenant_db, {
        name => $name, capacity => 10, project_id => $program->id, location_id => $location->id,
        teacher_id => $teacher->id, days => ['2027-07-05'], start => '09:00', minutes => 60,
    } );
}

subtest 'session ids from another program are refused' => sub {
    my $other = foreign_session( $db, 'Other week', $site, $user{staff} );
    offer_refused( qr/Choose at least one of the program&#39;s sessions/,
        resource_ids => [ $sessions[0]->id, $other->id ], offer_name => 'Camp mixed' );
    ok !Registry::DAO::Offer->find( $db, { name => 'Camp mixed' } ), 'no offer is made';
};

subtest 'session ids from another tenant are refused' => sub {
    Test::Registry::Fixtures::create_tenant( $db, { name => 'Other camp co', slug => 'other_camp' } );
    my $other    = Registry::DAO->new( url => $test_db->uri, schema => 'other_camp' );
    my $other_db = $other->db;
    my $teacher  = Test::Registry::Fixtures::create_user( $other,
        { username => 'their_staff', name => 'Their Staff', email => 'staff@their.test', user_type => 'staff' } );
    my $there    = Test::Registry::Fixtures::create_location( $other_db, { name => 'Their lake', slug => 'their-lake' } );
    my $theirs   = foreign_session( $other_db, 'Their week', $there, $teacher );
    offer_refused( qr/Choose at least one of the program&#39;s sessions/, resource_ids => [ $theirs->id ], offer_name => 'Camp theirs' );
};

subtest 'a refund cutoff on a session and a resource without days is refused' => sub {
    my $plain = Test::Registry::Fixtures::create_resource( $db, { name => 'Canoe', kind => 'finite', capacity => 4 } );
    like Registry::DAO::WorkflowSteps::RefundPolicy->refusal( $db,
        { offer_basics => { resource_ids => [ $sessions[0]->id, $plain->id ] } },
        { kind => 'full_until_cutoff', cutoff_hours => 24, approval => 'none' } ) // '',
        qr/A refund cutoff needs an offer bound to one occurrence, covering a class, or over sessions/,
        'every resource must have days';
};

subtest 'sibling offers that are not current are refused' => sub {
    my $draft = Registry::DAO::Offer->create( $db, { name => 'Never published' } );
    to_conditions('Camp draft sibling');
    like submit_step( 'conditions', sibling => 'offers', sibling_offer_ids => [ $draft->id ] ), qr{/conditions\z},
        'the step stays';
    $t->content_like( qr/Choose the offers a sibling&#39;s place counts from among your offers/, 'and says why' );
};

subtest 'an unparseable early-bird time is refused' => sub {
    to_conditions('Camp someday');
    like submit_step( 'conditions', sibling => 'none', early_bird_until => 'next tuesday' ), qr{/conditions\z}, 'the step stays';
    $t->content_like( qr/The early-bird time is a date and time like 2027-03-01T00:00/, 'and says why' );
};

subtest 'an early-bird time in year 0 is refused' => sub {
    to_conditions('Camp year zero');
    like submit_step( 'conditions', sibling => 'none', early_bird_until => '0000-03-01T00:00' ), qr{/conditions\z}, 'the step stays';
    $t->content_like( qr/The early-bird time is a date and time like 2027-03-01T00:00/, 'and says why' );
};

subtest 'a sibling offer retired after the conditions step is refused at publish' => sub {
    my $counted = current('Camp sibling');
    to_conditions('Camp late sibling');
    like submit_step( 'conditions', sibling => 'offers', sibling_offer_ids => [ $counted->offer_id ] ),
        qr{/one-time-payment\z}, 'a sibling of a Camp sibling holder';
    submit_step( 'one-time-payment', one_time => 'offered' );
    submit_step( 'instalment-payment', instalments => 'declined' );
    submit_step( 'refund-policy', refund => 'none', approval => 'none' );
    submit_step( 'change-policy', change => 'none' );
    submit_step( 'use-policy', use => 'none' );
    like submit_step( 'expiry-policy', expiry => 'end_of_occurrence' ), qr{/publish\z}, 'at the review';
    # Retired: no DAO method takes an offer off sale without a new version.
    $db->update( 'offer_versions', { superseded_at => \'now()' }, { id => $counted->id } );
    like submit_step( 'publish', action => 'publish' ), qr{/publish\z}, 'publish stays';
    $t->content_like( qr/Choose the offers a sibling&#39;s place counts from among your offers/, 'and says why' );
    ok !Registry::DAO::Offer->find( $db, { name => 'Camp late sibling' } ), 'no offer is made';
};

done_testing;
