#!/usr/bin/env perl
# ABOUTME: The location-creation workflow asks for the location's time zone and
# ABOUTME: creates nothing when the zone is missing or not a real IANA name.

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::Location;
use Mojo::File;

my $test_db  = Test::Registry::DB->new;
my $db       = $test_db->db;
my $workflow = Registry::DAO::Workflow->from_yaml( $db, Mojo::File->new('workflows/location-creation.yml')->slurp );
my $complete = Registry::DAO::WorkflowStep->find( $db, { workflow_id => $workflow->id, slug => 'complete' } );

subtest 'a missing or unknown zone creates nothing' => sub {
    for my $zone ( undef, 'Mars/Olympus' ) {
        my $run = $workflow->new_run($db);
        $run->update_data( $db, { name => 'Zoneless Hall', time_zone => $zone } );
        my $result = $complete->process( $db, {}, $run );
        like join( ' ', @{ $result->{errors} // [] } ), qr/time zone/i, 'refused: ' . ( $zone // 'undef' );
    }
    is scalar( Registry::DAO::Location->find( $db, { name => 'Zoneless Hall' } ) ), undef, 'no location made';
};

subtest 'a real zone is stored on the new location' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data( $db, { name => 'Zoned Hall', time_zone => 'America/Denver' } );
    my $result = $complete->process( $db, {}, $run );
    my $made   = Registry::DAO::Location->find( $db, { id => $result->{location} } );
    is $made && $made->time_zone, 'America/Denver', 'zone stored';
};

# Not in any shipped workflow, but a step class anyone may name in one.
subtest 'the with-address step refuses an unknown zone the same way' => sub {
    $workflow->add_step( $db, { slug => 'with-address', description => 'With address',
        class => 'Registry::DAO::WorkflowSteps::CreateLocationWithAddress' } );
    my $step = Registry::DAO::WorkflowStep->find( $db, { workflow_id => $workflow->id, slug => 'with-address' } );
    for my $zone ( undef, 'Mars/Olympus' ) {
        my $run    = $workflow->new_run($db);
        my $result = eval { $step->process( $db, { name => 'Addressed Hall', time_zone => $zone }, $run ) };
        like join( ' ', @{ ( $result // {} )->{errors} // [] } ), qr/time zone/i,
            'refused with a message: ' . ( $zone // 'undef' );
    }
    is scalar( Registry::DAO::Location->find( $db, { name => 'Addressed Hall' } ) ), undef, 'no location made';
};

done_testing;
