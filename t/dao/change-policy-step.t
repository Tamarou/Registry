#!/usr/bin/env perl
# ABOUTME: offer-publishing's change-policy step, driven through the real WorkflowProcessor as a tenant admin.
# ABOUTME: The admin chooses none, or a window, fee and same-offer targets on an occurrence-bound or class offer.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( import_all_workflows join_tenant );
use Registry::DAO;
use Registry::DAO::Offer;
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

# Seats bound to one occurrence, and seats bound to none.
my $bound = Registry::DAO::Resource->for_occurrence( $tdb, event_of( class_in() ) );
my $loose = Test::Registry::Fixtures::create_resource( $tdb,
    { name => 'Open studio seats', kind => 'finite', capacity => 10 } );

my %WINDOW = ( change => 'window', window_hours => 48, fee_cents => 1000, targets => 'same_offer' );

# Walks every step the stored workflow has, in order, as the admin, submitting
# valid answers merged with %override's fields for that slug; a slug mapped to
# undef is never submitted. Offers $bound unless offer-basics is overridden.
# Returns the run and each step's result by slug.
sub walk (%override) {
    my %fields = (
        'resource'         => { resource_mode => 'existing' },
        'offer-basics'     => { resource_id => $bound->id, offer_name => 'Wheel night' },
        'offer-price'      => { price_cents => 2500, currency => 'usd', units_per_acceptance => 1, per_booking_cap => 2 },
        'one-time-payment' => { one_time => 'offered' },
        'refund-policy'    => { refund => 'none' },
        'change-policy'    => { change => 'none' },
        'use-policy'       => { use => 'none' },
        'publish'          => { action => 'publish', refund => 'none' },
    );
    my $workflow = $tenant_dao->find( Workflow => { slug => 'offer-publishing' } );
    my $run      = Registry::WorkflowProcessor->new( dao => $tenant_dao )
        ->new_run( $workflow, { user => { id => $admin->id, name => $admin->name } } );
    my %result;
    for ( my $step = $workflow->first_step($tdb) ; $step ; $step = $step->next_step($tdb) ) {
        my $slug = $step->slug;
        next if exists $override{$slug} && !defined $override{$slug};
        # Expiry fits the offer: end of occurrence when it has one, else never.
        if ( $slug eq 'expiry-policy' && !exists $override{$slug} ) {
            my $r = $run->process( $tdb, $step, { expiry => 'end_of_occurrence' } );
            $r = $run->process( $tdb, $step, { expiry => 'never' } ) if $r->{errors};
            $result{$slug} = $r;
            next;
        }
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

# Walks with change-policy submitted $fields and checks nothing publishes.
sub refused ( $label, $fields, %override ) {
    my $before = published_count();
    my ( $run, $result ) = walk( 'change-policy' => $fields, %override );
    ok $result->{'change-policy'}{errors}, "$label stays with an error";
    ok !$run->data->{change_policy}, 'and the run records no change policy';
    ok $result->{publish}{errors}, 'and publish refuses the run';
    is published_count(), $before, 'and nothing is published';
}

subtest 'change none is published' => sub {
    my ( $run, $result ) = walk( 'change-policy' => { change => 'none' } );
    ok $result->{'change-policy'} && !$result->{'change-policy'}{errors}, 'the change-policy step accepts none';
    my $version = published_version($run);
    ok $version && $version->is_published, 'the offer publishes';
    is_deeply $version && $version->policies->{change}, { kind => 'none' }, 'with no change allowed';
};

subtest 'change window fee and targets are published' => sub {
    my %class = ( resource => { resource_mode => 'class', class_project_id => class_in() } );
    for my $case (
        [ 'an occurrence-bound offer', \%WINDOW, () ],
        [ 'a class offer',             \%WINDOW, %class ],
        [ 'a free change',             { %WINDOW, fee_cents => 0 }, () ],
    ) {
        my ( $label, $fields, %override ) = @$case;
        my ( $run, $result ) = walk( 'change-policy' => $fields, %override );
        ok !$result->{'change-policy'}{errors}, "the step accepts a window on $label"
            or diag explain $result->{'change-policy'};
        my $version = published_version($run);
        ok $version && $version->is_published, 'the offer publishes' or diag explain $result->{publish};
        is_deeply $version && $version->policies->{change},
            { kind => 'window', window_hours => 48, fee_cents => $fields->{fee_cents}, targets => 'same_offer' },
            'carrying exactly those change terms';
    }
};

subtest 'invalid window or fee stays with an error' => sub {
    for my $field (qw( window_hours fee_cents )) {
        refused( "a missing $field",  { %WINDOW, $field => undef } );
        refused( "a negative $field", { %WINDOW, $field => -1 } );
        refused( "a non-integer $field '$_'", { %WINDOW, $field => $_ } ) for '10.00', '2.5', '1e3', 'ten', '';
        refused( "a list $field", { %WINDOW, $field => [48] } );
    }
};

subtest 'targets other than same offer refused' => sub {
    refused( "targets '$_'", { %WINDOW, targets => $_ } ) for qw( any_offer all );
    refused( 'missing targets', { %WINDOW, targets => undef } );
    refused( 'a list of targets', { %WINDOW, targets => ['same_offer'] } );

    # Another offer of this tenant, and one in another tenant's schema.
    my $mine = Registry::DAO::Offer->create( $tdb, { name => 'Kiln night' } );
    Test::Registry::Fixtures::create_tenant( $dao, { name => 'Glass Studio', slug => 'glass_studio' } );
    my $theirs = Registry::DAO::Offer->create( $dao->connect_schema('glass_studio')->db, { name => 'Glass night' } );
    refused( "another offer's id", { %WINDOW, targets => $mine->id } );
    refused( "another tenant's offer id", { %WINDOW, targets => $theirs->id } );
};

subtest 'change window refused without an occurrence' => sub {
    my $unbounded = Test::Registry::Fixtures::create_resource( $tdb, { name => 'Card processing', kind => 'unbounded' } );
    for my $resource ( $loose, $unbounded ) {
        refused( 'a window on ' . $resource->name, \%WINDOW,
            'offer-basics' => { resource_id => $resource->id, offer_name => 'Drop in' } );
    }
    my ( $run ) = walk( 'change-policy' => { change => 'none' },
        'offer-basics' => { resource_id => $loose->id, offer_name => 'Drop in' } );
    ok published_version($run), 'change none still publishes on an offer with no occurrence';
};

subtest 'unknown or skipped change choice publishes nothing' => sub {
    refused( "change '$_'", { change => $_ } ) for 'sometimes', 'NONE', 'reschedule', '';
    refused( 'a missing change value', { change => undef } );
    refused( 'a list change value', { change => ['none'] } );

    my $before = published_count();
    my ( $run, $result ) = walk( 'change-policy' => undef );
    ok $result->{publish}{errors}, 'skipping the choice makes publish stay with an error';
    like join( ' ', ( $result->{publish}{errors} // [] )->@* ), qr/change policy/i, 'asking for the change policy';
    ok !$run->data->{published_offer_version_id}, 'the run records no version';
    is published_count(), $before, 'and nothing is published';
};

subtest 'change details ignored with change none' => sub {
    my ( $run, $result ) = walk( 'change-policy' => { %WINDOW, change => 'none', targets => 'anything' } );
    ok !$result->{'change-policy'}{errors}, 'none with window details is accepted';
    is_deeply $run->data->{change_policy}, { kind => 'none' }, 'the run records none alone';
    my $version = published_version($run);
    is_deeply $version && $version->policies->{change}, { kind => 'none' }, 'and none alone is published';
};

subtest 'change value resubmitted at publish is ignored' => sub {
    my ( $run ) = walk( 'publish' => { change => 'window', change_policy => { %WINDOW, kind => 'window' } } );
    my $version = published_version($run);
    ok $version && $version->is_published, 'publish with a window in its form still publishes';
    is_deeply $version && $version->policies->{change}, { kind => 'none' },
        'with the change policy the change-policy step recorded';
};

done_testing;
