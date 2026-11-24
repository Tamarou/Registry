#!/usr/bin/env perl
# ABOUTME: offer-publishing's refund-policy step, driven through the real WorkflowProcessor as a tenant admin.
# ABOUTME: The admin chooses none, full until a cutoff, or keep the fee explicitly; anything else publishes nothing.
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

# A resource bound to no occurrence, one that is an occurrence, and a class.
my $seats = Test::Registry::Fixtures::create_resource( $tdb,
    { name => 'Wheel seats', kind => 'finite', capacity => 10 } );
my $class = $tdb->insert( 'projects', { name => 'Wheel class', slug => 'wheel-class' }, { returning => 'id' } )
    ->hash->{id};
my $teacher = $tdb->insert( 'users', { username => 'wheel-teacher' }, { returning => 'id' } )->hash->{id};
my $room    = $tdb->insert( 'locations', { name => 'Wheel room', slug => 'wheel-room' }, { returning => 'id' } )
    ->hash->{id};
my $event = $tdb->insert( 'events', {
    project_id => $class, location_id => $room, teacher_id => $teacher,
    time       => '2099-03-01T10:00:00Z', duration => 90, capacity => 10,
}, { returning => 'id' } )->hash->{id};
my $occurrence = Registry::DAO::Resource->for_occurrence( $tdb, $event );

# Walks every step the stored workflow has, in order, as the admin, submitting
# valid answers merged with %override's fields for that slug; a slug mapped to
# undef is never submitted. Returns the run and each step's result by slug.
sub walk (%override) {
    my %fields = (
        'resource'                    => { resource_mode => 'existing' },
        'offer-basics'                => { resource_id => $seats->id, offer_name => 'Wheel night' },
        'offer-price'                 => { price_cents => 2500, currency => 'usd', units_per_acceptance => 1, per_booking_cap => 2 },
        'one-time-payment'            => { one_time => 'offered' },
        'percentage-of-sales-payment' => { percentage_of_sales => 'declined' },
        'refund-policy'               => { refund => 'none' },
        'change-policy'               => { change => 'none' },
        'use-policy'                  => { use => 'none' },
        'publish'                     => { action => 'publish' },
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

# Overrides that make the offer one bound to the occurrence.
my %on_occurrence = ( 'offer-basics' => { resource_id => $occurrence->id } );

# Overrides that make the offer carry a percentage-of-sales plan.
my %with_percentage = (
    'percentage-of-sales-payment' => { percentage_of_sales => 'offered', rate_percent => '2.5' },
);

sub published_version ($run) {
    my $id = $run->data->{published_offer_version_id} or return;
    return Registry::DAO::OfferVersion->find( $tdb, { id => $id } );
}

sub published_count {
    return $tdb->query('SELECT count(*) FROM offer_versions WHERE published_at IS NOT NULL')->array->[0];
}

subtest 'refund none is published' => sub {
    my ( $run, $result ) = walk( 'refund-policy' => { refund => 'none' } );
    ok $result->{'refund-policy'} && !$result->{'refund-policy'}{errors}, 'the refund-policy step accepts none';
    my $version = published_version($run);
    ok $version && $version->is_published, 'the offer publishes';
    is_deeply $version && $version->policies->{refund}, { kind => 'none' }, 'carrying a none refund policy';
};

subtest 'refund full until cutoff is published' => sub {
    my ( $run, $result ) = walk( %on_occurrence,
        'refund-policy' => { refund => 'full_until_cutoff', cutoff_hours => 24 } );
    ok $result->{'refund-policy'} && !$result->{'refund-policy'}{errors},
        'the refund-policy step accepts a 24 hour cutoff on an occurrence-bound offer'
        or diag explain $result->{'refund-policy'};
    my $version = published_version($run);
    ok $version && $version->is_published, 'the offer publishes';
    is_deeply $version && $version->policies->{refund}, { kind => 'full_until_cutoff', cutoff_hours => 24 },
        'carrying a full refund until 24 hours before';

    ( $run, $result ) = walk(
        'resource'      => { resource_mode => 'class', class_project_id => $class },
        'refund-policy' => { refund => 'full_until_cutoff', cutoff_hours => 0 },
    );
    $version = published_version($run);
    ok $version && $version->is_published, 'an offer covering a class publishes too'
        or diag explain $result;
    is_deeply $version && $version->policies->{refund}, { kind => 'full_until_cutoff', cutoff_hours => 0 },
        'with a cutoff at the start itself';
};

subtest 'refund keep fee is published on a percentage offer' => sub {
    my ( $run, $result ) = walk( %with_percentage, 'refund-policy' => { refund => 'keep_fee_with_admin_exception' } );
    ok $result->{'refund-policy'} && !$result->{'refund-policy'}{errors},
        'the refund-policy step accepts keep the fee on a percentage offer'
        or diag explain $result->{'refund-policy'};
    my $version = published_version($run);
    ok $version && $version->is_published, 'the offer publishes';
    is_deeply $version && $version->policies->{refund}, { kind => 'keep_fee_with_admin_exception' },
        'carrying a keep-the-fee refund policy';
};

subtest 'unknown refund value stays with an error' => sub {
    my $before = published_count();
    for my $value ( 'partial', 'full_until', 'keep_fee', 'NONE', '', undef, ['none'] ) {
        my $label = ref $value ? 'a list value' : !defined $value ? 'a missing value'
            : $value eq '' ? 'an empty value' : "'$value'";
        my ( $run, $result ) = walk( %on_occurrence, %with_percentage,
            'refund-policy' => { refund => $value, cutoff_hours => 24 } );
        ok $result->{'refund-policy'}{errors}, "$label stays with an error";
        ok !$run->data->{refund_policy}, 'and the run records no refund policy';
        ok $result->{publish}{errors}, 'and publish refuses the run';
    }
    is published_count(), $before, 'nothing is published';
};

subtest 'keep fee refused without a percentage plan' => sub {
    my $before = published_count();
    my ( $run, $result ) = walk( 'refund-policy' => { refund => 'keep_fee_with_admin_exception' } );
    ok $result->{'refund-policy'}{errors}, 'keep the fee on a one-time seat offer stays with an error';
    like join( ' ', ( $result->{'refund-policy'}{errors} // [] )->@* ), qr/percentage/i,
        'naming the percentage-of-sales plan it needs';
    ok $result->{publish}{errors}, 'and publish refuses the run';

    # Chosen on a percentage offer, then the percentage plan declined again.
    ( $run, $result ) = walk( %with_percentage,
        'refund-policy' => { refund => 'keep_fee_with_admin_exception' }, 'publish' => undef );
    my $workflow = $tenant_dao->find( Workflow => { slug => 'offer-publishing' } );
    $run->process( $tdb, $workflow->get_step( $tdb, { slug => 'percentage-of-sales-payment' } ),
        { percentage_of_sales => 'declined' } );
    my $publish = $run->process( $tdb, $workflow->get_step( $tdb, { slug => 'publish' } ), { action => 'publish' } );
    like join( ' ', ( $publish->{errors} // [] )->@* ), qr/percentage/i,
        'publish refuses keep the fee once the percentage plan is declined';
    is published_count(), $before, 'nothing is published';
};

subtest 'invalid cutoff hours stay with an error' => sub {
    my $before = published_count();
    for my $hours ( undef, '', -1, '-24', '24h', '2.5', ' 24', ['24'] ) {
        my $label = ref $hours ? 'a list value' : !defined $hours ? 'missing hours' : "hours '$hours'";
        my ( $run, $result ) = walk( %on_occurrence,
            'refund-policy' => { refund => 'full_until_cutoff', cutoff_hours => $hours } );
        ok $result->{'refund-policy'}{errors}, "$label stays with an error";
        ok $result->{publish}{errors}, 'and publish refuses the run';
    }
    is published_count(), $before, 'nothing is published';
};

subtest 'cutoff refund refused without an occurrence' => sub {
    my $before = published_count();
    my ( $run, $result ) = walk( 'refund-policy' => { refund => 'full_until_cutoff', cutoff_hours => 24 } );
    ok $result->{'refund-policy'}{errors}, 'a cutoff on an offer bound to no occurrence stays with an error';
    like join( ' ', ( $result->{'refund-policy'}{errors} // [] )->@* ), qr/occurrence|class/i,
        'naming the occurrence or class it needs';
    ok $result->{publish}{errors}, 'and publish refuses the run';
    is published_count(), $before, 'nothing is published';
};

subtest 'skipped refund choice publishes nothing' => sub {
    my $before = published_count();
    my ( $run, $result ) = walk( 'refund-policy' => undef );
    ok $result->{publish}{errors}, 'publish stays with an error';
    like join( ' ', ( $result->{publish}{errors} // [] )->@* ), qr/refund policy/i, 'asking for the refund policy';
    ok !$run->data->{published_offer_version_id}, 'the run records no version';
    is published_count(), $before, 'and nothing is published';
};

subtest 'cutoff hours ignored with refund none' => sub {
    my ( $run, $result ) = walk( %on_occurrence, 'refund-policy' => { refund => 'none', cutoff_hours => 24 } );
    ok !$result->{'refund-policy'}{errors}, 'refund none with cutoff hours is accepted';
    is_deeply $run->data->{refund_policy}, { kind => 'none' }, 'the run records no cutoff';
    my $version = published_version($run);
    is_deeply $version && $version->policies->{refund}, { kind => 'none' }, 'and the version carries none';
};

subtest 'refund resubmitted at publish is ignored' => sub {
    for my $value (qw( full_until_cutoff keep_fee_with_admin_exception partial )) {
        my ( $run, $result ) = walk( %on_occurrence, %with_percentage,
            'refund-policy' => { refund => 'none' },
            'publish'       => { refund => $value, cutoff_hours => 24,
                                 refund_policy => { kind => $value, cutoff_hours => 24 } },
        );
        my $version = published_version($run);
        ok $version && $version->is_published, "publish with refund '$value' in its form still publishes";
        is_deeply $version && $version->policies->{refund}, { kind => 'none' },
            'with the refund policy the refund-policy step recorded';
    }
};

subtest 'published refund policy cannot be updated' => sub {
    my ($run) = walk( %on_occurrence, 'refund-policy' => { refund => 'full_until_cutoff', cutoff_hours => 24 } );
    my $version = published_version($run) or return fail 'nothing published';
    my $ok = eval {
        $tdb->query( q{UPDATE offer_versions SET policies = jsonb_set(policies, '{refund}', '{"kind":"none"}') WHERE id = ?},
            $version->id );
        1;
    };
    ok !$ok, 'a direct UPDATE of the refund policy is refused by the database';
    like $@, qr/immutable once published/, 'as immutable';
    is_deeply Registry::DAO::OfferVersion->find( $tdb, { id => $version->id } )->policies->{refund},
        { kind => 'full_until_cutoff', cutoff_hours => 24 }, 'and the policy is unchanged';
};

done_testing;
