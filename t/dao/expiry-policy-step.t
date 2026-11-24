#!/usr/bin/env perl
# ABOUTME: offer-publishing's expiry-policy step, driven through the real WorkflowProcessor as a tenant admin.
# ABOUTME: Occurrence-bound and class offers expire at the end of the occurrence; others never; no choice publishes nothing.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( import_all_workflows join_tenant );
use Registry::DAO;
use Registry::DAO::OfferVersion;
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

# A class (a projects row); returns its id.
sub class_in {
    return $tdb->insert( 'projects', { name => 'Class ' . ++$made, slug => "class-$made" },
        { returning => 'id' } )->hash->{id};
}

# An occurrence (an events row) of $class; returns its id.
sub event_of ($class) {
    my $teacher = $tdb->insert( 'users', { username => 'teacher-' . ++$made }, { returning => 'id' } )
        ->hash->{id};
    my $where = $tdb->insert( 'locations', { name => "Room $made", slug => "room-$made" },
        { returning => 'id' } )->hash->{id};
    return $tdb->insert( 'events', {
        project_id => $class, location_id => $where, teacher_id => $teacher,
        time       => "2099-03-0${\( $made % 9 + 1 )}T10:00:00Z", duration => 90, capacity => 10,
    }, { returning => 'id' } )->hash->{id};
}

# An occurrence-bound seats resource, and one with no occurrence.
sub occurrence_seats { Registry::DAO::Resource->for_occurrence( $tdb, event_of( class_in() ) ) }
my $open = Test::Registry::Fixtures::create_resource( $tdb, { name => 'Studio access', kind => 'unbounded' } );

# Walks every step the stored workflow has, in order, as the admin, submitting
# valid answers merged with %override's fields for that slug; a slug mapped to
# undef is never submitted. 'offer-basics' defaults to the unbounded resource;
# a 'class' key covers that class instead. Returns the run and each result.
sub walk (%override) {
    my $class = delete $override{class};
    my %fields = (
        'resource'         => $class ? { resource_mode => 'class', class_project_id => $class }
                                     : { resource_mode => 'existing' },
        'offer-basics'     => { $class ? () : ( resource_id => $open->id ), offer_name => 'Wheel night' },
        'offer-price'      => { price_cents => 2500, currency => 'usd', units_per_acceptance => 1, per_booking_cap => 1 },
        'one-time-payment' => { one_time => 'offered' },
        'use-policy'       => { use => 'none' },
        'expiry-policy'    => { expiry => 'never' },
        'publish'          => { action => 'publish', refund => 'none' },
    );
    my $workflow = $tenant_dao->find( Workflow => { slug => 'offer-publishing' } );
    my $run      = Registry::WorkflowProcessor->new( dao => $tenant_dao )
        ->new_run( $workflow, { user => { id => $admin->id, name => $admin->name } } );
    my %result;
    for ( my $step = $workflow->first_step($tdb) ; $step ; $step = $step->next_step($tdb) ) {
        my $slug = $step->slug;
        next if exists $override{$slug} && !defined $override{$slug};
        $result{$slug} = $run->process( $tdb, $step, { ( $fields{$slug} // {} )->%*, ( $override{$slug} // {} )->%* } );
    }
    return ( $run, \%result );
}

sub published_version ($run) {
    my $id = $run->data->{published_offer_version_id} or return;
    return Registry::DAO::OfferVersion->find( $tdb, { id => $id } );
}

sub published_count {
    return $tdb->query('SELECT count(*) FROM offer_versions WHERE published_at IS NOT NULL')->array->[0];
}

subtest 'end of occurrence expiry is published' => sub {
    my @cases = (
        [ 'an occurrence-bound seats resource' => ( 'offer-basics' => { resource_id => occurrence_seats()->id } ) ],
        [ 'a class offer' => ( class => class_in() ) ],
    );
    for my $case (@cases) {
        my ( $label, %override ) = @$case;
        my ( $run, $result ) = walk( %override, 'expiry-policy' => { expiry => 'end_of_occurrence' } );
        ok $result->{'expiry-policy'} && !$result->{'expiry-policy'}{errors},
            "the expiry-policy step accepts end of occurrence on $label" or diag explain $result->{'expiry-policy'};
        my $version = published_version($run);
        ok $version && $version->is_published, 'the offer publishes' or diag explain $result->{publish};
        is_deeply $version && $version->policies->{expiry}, { kind => 'end_of_occurrence' },
            'carrying an end of occurrence expiry policy';
    }
};

subtest 'never expiry is published without an occurrence' => sub {
    my $loose = Test::Registry::Fixtures::create_resource( $tdb, { name => 'Loose seats', kind => 'finite', capacity => 4 } );
    for my $resource ( $open, $loose ) {
        my ( $run, $result ) = walk(
            'offer-basics'  => { resource_id => $resource->id },
            'expiry-policy' => { expiry => 'never' },
        );
        ok $result->{'expiry-policy'} && !$result->{'expiry-policy'}{errors},
            'the expiry-policy step accepts never on ' . $resource->name;
        my $version = published_version($run);
        ok $version && $version->is_published, 'the offer publishes' or diag explain $result->{publish};
        is_deeply $version && $version->policies->{expiry}, { kind => 'never' }, 'carrying a never expiry policy';
    }
};

subtest 'end of occurrence refused without an occurrence' => sub {
    my $before = published_count();
    my ( $run, $result ) = walk( 'expiry-policy' => { expiry => 'end_of_occurrence' } );
    ok $result->{'expiry-policy'}{errors}, 'end of occurrence on an unbounded resource stays with an error';
    ok !$run->data->{expiry_policy}, 'and the run records no expiry policy';
    ok $result->{publish}{errors}, 'and publish refuses the run';
    is published_count(), $before, 'nothing is published';
};

subtest 'skipped expiry choice publishes nothing' => sub {
    my $before = published_count();
    my ( $run, $result ) = walk( 'expiry-policy' => undef );
    ok $result->{publish}{errors}, 'publish stays with an error';
    like join( ' ', ( $result->{publish}{errors} // [] )->@* ), qr/expiry policy/i, 'asking for the expiry policy';
    ok !$run->data->{published_offer_version_id}, 'the run records no version';
    is published_count(), $before, 'and nothing is published';
};

done_testing;
