#!/usr/bin/env perl
# ABOUTME: A change checks the entitlement's stamped change policy, lists same-offer targets and holds the target's seats.
# ABOUTME: Drives ChooseChangeTarget and HoldChangeTarget through a real workflow run in a tenant schema.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO::Resource;
use Registry::DAO::Offer;
use Registry::DAO::OfferVersion;
use Registry::DAO::Entitlement;
use Registry::DAO::Tenant;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::PriceOps::Hold;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $SLUG = 'change_house';
Registry::DAO::Tenant->create( $db, { name => 'Change House', slug => $SLUG } );
$db->query( 'SELECT clone_schema(dest_schema => ?)', $SLUG );
my $studio = Registry::DAO->new( url => $dao->url, schema => $SLUG )->db;

my %WINDOW = ( kind => 'window', window_hours => 48, fee_cents => 1000, targets => 'same_offer' );
my $made   = 0;

sub person () {
    return $studio->insert( 'users', { username => 'p-' . ++$made }, { returning => 'id' } )->hash->{id};
}

# A class whose occurrences start $hours from now, each with $capacity seats
# and its own resource, and a published class offer version covering them
# with change policy $change. Returns the version and the resources.
sub occurrences ( $change, @hours ) {
    my $capacity = ref $hours[-1] ? pop(@hours)->{capacity} : 4;
    my $class = $studio->insert( 'projects', { name => 'Class ' . ++$made, slug => "class-$made" },
        { returning => 'id' } )->hash->{id};
    my @resources = map {
        my $room = $studio->insert( 'locations', { name => 'Room ' . ++$made, slug => "room-$made" },
            { returning => 'id' } )->hash->{id};
        my $event = $studio->insert( 'events', {
            project_id => $class, location_id => $room, teacher_id => person(),
            time       => \"now() + interval '$_ hours'", duration => 90, capacity => $capacity,
        }, { returning => 'id' } )->hash->{id};
        Registry::DAO::Resource->for_occurrence( $studio, $event );
    } @hours;
    my $version = Registry::DAO::Offer->create( $studio, { name => 'Wheel class ' . $made } )
        ->draft( $studio, offer_terms( undef, class_project_id => $class,
            policies => { refund => { kind => 'none' }, change => $change } ) )->publish($studio);
    return ( $version, @resources );
}

# An entitlement under $version holding $units seats of $resource.
sub booking ( $version, $resource, $units = 1, %more ) {
    return Registry::DAO::Entitlement->grant( $studio, {
        holder_user_id   => person(),
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
        starts_at        => '2020-01-01T00:00:00Z',
        resource_id      => $resource->id,
        units            => $units,
        %more,
    } );
}

my $workflow = Registry::DAO::Workflow->create( $studio,
    { slug => 'change-test', name => 'Change test', description => 'change steps under test' } );
my $choose = Registry::DAO::WorkflowStep->create( $studio, {
    workflow_id => $workflow->id, slug => 'choose-target',
    class       => 'Registry::DAO::WorkflowSteps::ChooseChangeTarget', description => 'choose',
} );
my $hold_step = Registry::DAO::WorkflowStep->create( $studio, {
    workflow_id => $workflow->id, slug => 'hold-target',
    class       => 'Registry::DAO::WorkflowSteps::HoldChangeTarget', description => 'hold',
    depends_on  => $choose->id,
} );
$_ = Registry::DAO::WorkflowStep->find( $studio, { id => $_->id } ) for $choose, $hold_step;

# A run that chose to change $entitlement; returns it and ChooseChangeTarget's result.
sub chosen ($entitlement) {
    my $run    = $workflow->new_run($studio);
    my $result = $run->process( $studio, $choose, { entitlement_id => $entitlement->id } );
    return ( $run, $result );
}

sub hold_target ( $run, $resource, %more ) {
    return $run->process( $studio, $hold_step, { target_occurrence_id => $resource->id, %more } );
}

sub live_holds ($run) {
    my $live = Registry::PriceOps::Hold->live_sql('holds');
    return $studio->query( "SELECT * FROM holds WHERE workflow_run_id = ? AND $live", $run->id )->hashes->to_array;
}

subtest 'change lists same offer and holds target' => sub {
    my ( $version, $held, $target ) = occurrences( \%WINDOW, 72, 96 );
    my ( undef, $elsewhere ) = occurrences( \%WINDOW, 96 );
    my $e = booking( $version, $held, 2 );

    my ( $run, $chose ) = chosen($e);
    ok !$chose->{errors}, 'the change is allowed' or diag explain $chose->{errors};
    is_deeply [ map { $_->{id} } $chose->{change_targets}->@* ], [ $target->id ],
        'it lists the other occurrence of the same offer, not its own nor another offer\'s';

    my $data = hold_target( $run, $target );
    ok !$data->{errors}, 'the hold step accepts it' or diag explain $data->{errors};
    my $holds = live_holds($run);
    is scalar @$holds, 1, 'one live hold is placed for the run';
    is $holds->[0]{resource_id}, $target->id, 'on the target';
    is $holds->[0]{units}, 2, "for the entitlement's seat count";
    is $target->free_units($studio), 2, 'so the target has two of four seats free';
    is_deeply $e->units( $studio, $held->id ), [ 1, 2 ], 'the entitlement is not moved yet';
    is_deeply $data->{change}, {
        entitlement_id       => $e->id,
        target_occurrence_id => $target->id,
        hold_id              => $holds->[0]{id},
        fee_cents            => 1000,
        offer_version_id     => $version->id,
    }, 'and the run carries the change with the stamped fee';
};

done_testing;
