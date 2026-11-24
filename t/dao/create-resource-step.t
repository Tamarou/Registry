#!/usr/bin/env perl
# ABOUTME: offer-publishing's first step, driven through the real WorkflowProcessor: use, create or cover resources.
# ABOUTME: A tenant admin creates a finite or unbounded resource in its schema, picks an existing one, or covers a class.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( import_all_workflows join_tenant publish_offer );
use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::Resource;
use Registry::Utility::WorkflowProcessor;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

import_all_workflows($dao);
Test::Registry::Fixtures::create_tenant( $dao, { name => 'Clay Studio', slug => 'clay_studio' } );
my $tenant_dao = Registry::DAO->new( url => $test_db->uri, schema => 'clay_studio' );
my $tdb        = $tenant_dao->db;
import_all_workflows($tenant_dao);

my $admin = Test::Registry::Fixtures::create_user( $dao,
    { username => 'clay_admin', name => 'Clay Admin', email => 'admin@clay.test', user_type => 'admin' } );
join_tenant( $dao, $admin, 'admin', 'clay_studio' );

my $made = 0;

# A class (a projects row) in $db; returns its id.
sub class_in ( $db = $tdb ) {
    return $db->insert( 'projects', { name => 'Class ' . ++$made, slug => "class-$made" },
        { returning => 'id' } )->hash->{id};
}

# An occurrence (an events row) of $class in $db; returns its id.
sub event_of ( $class, $db = $tdb ) {
    my $teacher = $db->insert( 'users', { username => 'teacher-' . ++$made }, { returning => 'id' } )
        ->hash->{id};
    my $where = $db->insert( 'locations', { name => "Room $made", slug => "room-$made" },
        { returning => 'id' } )->hash->{id};
    return $db->insert( 'events', {
        project_id => $class, location_id => $where, teacher_id => $teacher,
        time       => "2099-03-0${\( $made % 9 + 1 )}T10:00:00Z", duration => 90, capacity => 10,
    }, { returning => 'id' } )->hash->{id};
}

sub workflow ( $workflow_dao = $tenant_dao ) {
    return $workflow_dao->find( Workflow => { slug => 'offer-publishing' } );
}

# A new run of offer-publishing as $user with the resource step submitted
# $fields. Returns the run and the step's result.
sub resource_step ( $user, $fields ) {
    my $run = Registry::WorkflowProcessor->new( dao => $tenant_dao )
        ->new_run( workflow(), { user => { id => $user->id, name => $user->name } } );
    my $step = workflow()->get_step( $tdb, { slug => 'resource' } );
    return ( $run, $run->process( $tdb, $step, $fields ) );
}

sub resource_count ( $db = $tdb ) {
    return $db->query('SELECT count(*) FROM resources')->array->[0];
}

subtest 'resource is the first step' => sub {
    is workflow()->first_step($tdb)->slug, 'resource', 'offer-publishing starts at the resource step';
    is workflow()->first_step($tdb)->next_step($tdb)->slug, 'offer-basics', 'and goes on to offer-basics';
};

subtest 'admin creates a finite seats resource' => sub {
    my $event  = event_of( class_in() );
    my $before = resource_count();
    my ( $run, $result ) = resource_step( $admin, {
        resource_mode => 'create', resource_name => 'Wheel seats', resource_kind => 'finite',
        capacity      => 10,       event_id      => $event,
    } );
    ok !$result->{errors}, 'the step accepts it' or diag explain $result;
    is resource_count(), $before + 1, 'one resource is written in the tenant schema';

    my $row = $tdb->query( 'SELECT * FROM resources WHERE name = ?', 'Wheel seats' )->hash;
    is $row->{kind},     'finite', 'finite';
    is $row->{capacity}, 10,       'with ten seats';
    is $row->{event_id}, $event,   'bound to the occurrence';
    is $dao->db->query( q{SELECT count(*) FROM registry.resources WHERE name = 'Wheel seats'} )->array->[0], 0,
        'and nothing is written in the registry schema';

    my $basics = workflow()->get_step( $tdb, { slug => 'offer-basics' } )->prepare_template_data( $tdb, $run );
    is $basics->{selected_resource_id}, $row->{id}, 'offer-basics preselects the new resource';
};

subtest 'admin creates an unbounded resource' => sub {
    my ( undef, $result ) = resource_step( $admin, {
        resource_mode => 'create', resource_name => 'Card processing', resource_kind => 'unbounded',
    } );
    ok !$result->{errors}, 'the step accepts it' or diag explain $result;
    my $row = $tdb->query( 'SELECT * FROM resources WHERE name = ?', 'Card processing' )->hash;
    is $row->{kind}, 'unbounded', 'an unbounded resource is written';
    is $row->{capacity}, undef, 'with no capacity';
};

subtest 'use existing creates no resource' => sub {
    my $before = resource_count();
    my ( $run, $result ) = resource_step( $admin, { resource_mode => 'existing' } );
    ok !$result->{errors}, 'the step passes through' or diag explain $result;
    is resource_count(), $before, 'and creates nothing';
    my $basics = workflow()->get_step( $tdb, { slug => 'offer-basics' } )->prepare_template_data( $tdb, $run );
    is $basics->{selected_resource_id}, undef, 'offer-basics preselects nothing';
};

subtest 'invalid finite capacity refused' => sub {
    my $before = resource_count();
    for my $case (
        [ 'a capacity of zero' => 0 ],
        [ 'a missing capacity' => undef ],
    ) {
        my ( $label, $capacity ) = @$case;
        my ( $run, $result ) = resource_step( $admin, {
            resource_mode => 'create', resource_name => 'Bad seats', resource_kind => 'finite',
            capacity      => $capacity,
        } );
        ok $result->{errors}, "$label stays with an error";
        ok !$run->data->{resource_choice}, 'and the run holds no choice';
    }
    is resource_count(), $before, 'nothing is created';
};

subtest 'admin publishes a class offer covering its occurrences' => sub {
    my ( $c, $d ) = ( class_in(), class_in() );
    my @in_c = map { Registry::DAO::Resource->for_occurrence( $tdb, event_of($c) )->id } 1 .. 2;
    Registry::DAO::Resource->for_occurrence( $tdb, event_of($d) );

    my ( $run, $result ) = resource_step( $admin, { resource_mode => 'class', class_project_id => $c } );
    ok !$result->{errors}, 'the step accepts the class' or diag explain $result;
    is $run->data->{resource_choice}{class_project_id}, $c, 'and writes its class key into the run';

    my $basics = workflow()->get_step( $tdb, { slug => 'offer-basics' } );
    $run->process( $tdb, $basics, { offer_name => 'Wheel class pass' } );
    is_deeply $run->data->{offer_basics}, { class_project_id => $c, offer_name => 'Wheel class pass' },
        'offer-basics takes the class key in place of a resource';

    my $version = publish_offer( $dao, 'clay_studio', $admin, {
        offer_name  => 'Wheel class pass', price_cents => 9000, currency => 'usd',
        units_per_acceptance => 1, per_booking_cap => 1,
        resource    => { resource_mode => 'class', class_project_id => $c },
    } );
    is $version->class_project_id, $c, 'the published version names the class';
    is $version->resource_id, undef, 'and no resource';
    is_deeply [ sort map { $_->id } $version->covered_resources($tdb)->@* ], [ sort @in_c ],
        'it covers the class\'s two occurrences and not the other class\'s';
};

done_testing;
