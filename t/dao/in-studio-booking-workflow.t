#!/usr/bin/env perl
# ABOUTME: The public in-studio-booking workflow through the real WorkflowProcessor: occurrence, offer and count, account, hold.
# ABOUTME: Holding takes count x seats per unit for a limited time and parks the run at payment; every refusal holds nothing.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( import_all_workflows );
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO;
use Registry::DAO::Offer;
use Registry::DAO::Project;
use Registry::DAO::Resource;
use Registry::DAO::Workflow;
use Registry::Utility::WorkflowProcessor;
use Registry::WorkflowStepClasses;
use Registry::PriceOps::Hold;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

my $SLUG = 'wheel_studio';
import_all_workflows($dao);
Test::Registry::Fixtures::create_tenant( $dao, { name => 'Wheel Studio', slug => $SLUG } );
my $tenant_dao = Registry::DAO->new( url => $test_db->uri, schema => $SLUG );
my $tdb        = $tenant_dao->db;
import_all_workflows($tenant_dao);

# The booker and the teacher, as users of the studio's schema.
my %user;
for my $who (qw( booker teacher )) {
    $user{$who} = Test::Registry::Fixtures::create_user( $dao,
        { username => "wheel_$who", name => "Wheel \u$who", email => "$who\@wheel.test", user_type => 'parent' } );
    $dao->db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)', $SLUG, $user{$who}->id );
}

my $room = Test::Registry::Fixtures::create_location( $tdb,
    { name => 'Wheel room', slug => 'wheel-room', time_zone => 'America/New_York' } );

my $workflow = $tenant_dao->find( Workflow => { slug => 'in-studio-booking' } );

# A class of $seats seats per occurrence, with one published occurrence
# starting $when (SQL, relative to now) and its seats.
sub occurrence ( $seats = 10, $when = q{now() + interval '7 days'}, $handle = $tdb, $location = $room ) {
    state $n = 0;
    ++$n;
    my $class = Registry::DAO::Project->create( $handle,
        { name => "Throwing $n", seats_per_occurrence => $seats, metadata => { location_id => $location->id } } );
    my $event = $handle->query( qq{
        INSERT INTO events (project_id, location_id, teacher_id, time, duration, capacity, status)
        VALUES (?, ?, ?, $when, 90, ?, 'published') RETURNING id
    }, $class->id, $location->id, $user{teacher}->id, $seats )->array->[0];
    return ( $class, Registry::DAO::Resource->for_occurrence( $handle, $event ) );
}

# A published offer for $class: $name, with %terms over offer_terms' defaults.
sub offer ( $class, $name = 'One seat', %terms ) {
    return Registry::DAO::Offer->create( $tdb, { name => $name } )
        ->draft( $tdb, offer_terms( undef, class_project_id => $class->id, per_booking_cap => 3,
            policies => { refund => { kind => 'none' } }, %terms ) )
        ->publish($tdb);
}

sub start () {
    my $u = $user{booker};
    return Registry::WorkflowProcessor->new( dao => $tenant_dao )
        ->new_run( $workflow, { user => { id => $u->id, name => $u->name }, user_id => $u->id } );
}

sub step ($slug) { $workflow->get_step( $tdb, { slug => $slug } ) }

sub errors_of ($result) { join ' ', ( ref $result eq 'HASH' ? $result->{errors} // [] : [] )->@* }

# Walks a fresh run to the hold step's result: occurrence, offer and count,
# the signed-in booker. Returns the run and each step's result by slug.
sub book ( $resource, $version, $count ) {
    my $run = start();
    my %r;
    $r{occurrence} = $run->process( $tdb, step('occurrence'), { occurrence_id => $resource->id } );
    $r{offer}      = $run->process( $tdb, step('offer'), { offer_version_id => $version->id, count => $count } );
    $r{account}    = $run->process( $tdb, step('account'), { action => 'continue_logged_in' } );
    $r{hold}       = $run->process( $tdb, step('hold'), {} );
    return ( $run, \%r );
}

sub live_holds ($resource) {
    my $live = Registry::PriceOps::Hold->live_sql('holds');
    return $tdb->query( "SELECT count(*) FROM holds WHERE resource_id = ? AND $live", $resource->id )->array->[0];
}

sub reload ($run) { $tenant_dao->find( WorkflowRun => { id => $run->id } ) }

subtest 'the workflow is public, with the design\'s steps' => sub {
    ok $workflow, 'in-studio-booking is imported into the tenant' or return;
    my @slugs;
    for ( my $s = $workflow->first_step($tdb) ; $s ; $s = $s->next_step($tdb) ) { push @slugs, $s->slug }
    is_deeply \@slugs, [qw( occurrence offer account hold payment )], 'occurrence, offer, account, hold, then payment';
    ok $workflow->public, 'it carries the public mark';
    ok Registry::WorkflowStepClasses::is_allowed("Registry::DAO::WorkflowSteps::$_"), "$_ is on the allowlist"
        for qw( ChooseOccurrence ChooseOfferAndUnits HoldSeats );
};

subtest 'two units of a two-seat offer hold four seats for a limited time and park at payment' => sub {
    my ( $class, $seats ) = occurrence(10);
    my $version = offer( $class, 'Couple', units_per_acceptance => 2, price_cents => 4500 );
    my ( $run, $r ) = book( $seats, $version, 2 );
    is errors_of( $r->{$_} ), '', "the $_ step is accepted" for qw( occurrence offer hold );

    my ($hold) = Registry::PriceOps::Hold->find( $tdb, { workflow_run_id => $run->id }, 'id' );
    ok $hold, 'a hold is placed for the run' or return;
    is $hold->resource_id, $seats->id, 'on the chosen occurrence';
    is $hold->units, 4, 'for 2 x 2 seats';
    ok $tdb->query( q{SELECT ?::timestamptz BETWEEN now() + interval '14 minutes' AND clock_timestamp() + interval '15 minutes'},
        $hold->expires_at )->array->[0], 'expiring 15 minutes after it is placed';
    is $seats->free_units($tdb), 6, 'leaving 6 seats';

    $run = reload($run);
    is $run->next_step($tdb)->slug, 'payment', 'the run is parked at payment';
    is_deeply $run->data->{owed_payment}, {
        offer_version_id => $version->id,
        payment_plan     => 'pay',
        amount_cents     => 9000,
        description      => 'Couple x 2',
        purpose          => 'booking',
        hold_id          => $hold->id,
    }, 'and owes 2 x the price against the hold';
};

sub run_holds ($run) {
    return $tdb->query( q{SELECT count(*) FROM holds WHERE workflow_run_id = ? AND state = 'held'}, $run->id )
        ->array->[0];
}

# Moves every hold of $run's to have lapsed a minute ago.
sub lapse ($run) {
    $tdb->query( q{UPDATE holds SET expires_at = clock_timestamp() - interval '1 minute' WHERE workflow_run_id = ?},
        $run->id );
}

subtest 'units over the per-booking cap refused' => sub {
    my ( $class, $seats ) = occurrence(10);
    my $version = offer( $class, 'Seat', per_booking_cap => 3 );
    my ( $run, $r ) = book( $seats, $version, 4 );
    like errors_of( $r->{offer} ), qr/at most 3 per booking/, 'four of a cap of three is refused with a message';
    is run_holds($run), 0, 'and holds nothing';

    # The run's count written past the offer step: the hold step asks again.
    ( $run, $r ) = book( $seats, $version, 3 );
    is errors_of( $r->{hold} ), '', 'the cap itself is held';
    $run->update_data( $tdb, { booking_count => 4 } );
    like errors_of( $run->process( $tdb, step('hold'), {} ) ), qr/at most 3 per booking/,
        'a count over the cap reaching the hold step is refused';
    is run_holds($run), 0, 'and gives back what the run held';
    is $seats->free_units($tdb), 10, 'every seat is free';
};

subtest 'full occurrence refused' => sub {
    my ( $class, $seats ) = occurrence(2);
    my $version = offer( $class, 'Seat' );
    my ( $first, $r ) = book( $seats, $version, 2 );
    is errors_of( $r->{hold} ), '', 'two seats of two are held';

    ( my $run, $r ) = book( $seats, $version, 1 );
    like errors_of( $r->{occurrence} ), qr/full/, 'choosing the full occurrence is refused with a message';
    ok !grep( { $_->{id} eq $seats->id } step('occurrence')->prepare_template_data( $tdb, $run )->{occurrences}->@* ),
        'and it is not listed';
    is run_holds($run), 0, 'and nothing is held';

    # Chosen with room, filled by another run before this one holds.
    my ( $c2, $two ) = occurrence(2);
    my $v2 = offer( $c2, 'Seat' );
    $run = start();
    $run->process( $tdb, step('occurrence'), { occurrence_id => $two->id } );
    $run->process( $tdb, step('offer'), { offer_version_id => $v2->id, count => 1 } );
    $run->process( $tdb, step('account'), { action => 'continue_logged_in' } );
    book( $two, $v2, 2 );
    like errors_of( $run->process( $tdb, step('hold'), {} ) ), qr/no longer has room for 1/,
        'holding in an occurrence filled meanwhile is refused';
    is run_holds($run), 0, 'and holds nothing';
    ok !reload($run)->data->{owed_payment}, 'and owes nothing';
};

subtest 'expired hold frees its seats' => sub {
    my ( $class, $seats ) = occurrence(4);
    my $version = offer( $class, 'Seat', per_booking_cap => 4 );
    my ($run) = book( $seats, $version, 4 );
    is $seats->free_units($tdb), 0, 'four of four seats are held';
    lapse($run);
    is $seats->free_units($tdb), 4, 'once the hold lapses all four are free';
    my ( $other, $r ) = book( $seats, $version, 4 );
    is errors_of( $r->{hold} ), '', 'and another booking holds them';
    is run_holds($other), 1, 'with its own hold';
};

done_testing;
