#!/usr/bin/env perl
# ABOUTME: offer-publishing's use-policy step, driven through the real WorkflowProcessor as a tenant admin.
# ABOUTME: The admin chooses optional attendance or none explicitly; anything else, or no choice, publishes nothing.
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

my $seats = Test::Registry::Fixtures::create_resource( $tdb,
    { name => 'Wheel seats', kind => 'finite', capacity => 10 } );

# Walks every step the stored workflow has, in order, as the admin, submitting
# valid answers merged with %override's fields for that slug; a slug mapped to
# undef is never submitted. Returns the run and each step's result by slug.
sub walk (%override) {
    my %fields = (
        'offer-basics'     => { resource_id => $seats->id, offer_name => 'Wheel night' },
        'offer-price'      => { price_cents => 2500, currency => 'usd', units_per_acceptance => 1, per_booking_cap => 2 },
        'one-time-payment' => { one_time => 'offered' },
        'refund-policy'    => { refund => 'none' },
        'change-policy'    => { change => 'none' },
        'use-policy'       => { use => 'none' },
        'expiry-policy'    => { expiry => 'never' },
        'publish'          => { action => 'publish' },
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

subtest 'optional attendance is published' => sub {
    my ( $run, $result ) = walk( 'use-policy' => { use => 'optional_attendance' } );
    ok $result->{'use-policy'} && !$result->{'use-policy'}{errors}, 'the use-policy step accepts optional attendance';
    my $version = published_version($run);
    ok $version && $version->is_published, 'the offer publishes';
    is_deeply $version && $version->policies->{use}, { kind => 'optional_attendance' },
        'carrying an optional attendance use policy';
};

subtest 'use none is published' => sub {
    my ( $run, $result ) = walk( 'use-policy' => { use => 'none' } );
    ok $result->{'use-policy'} && !$result->{'use-policy'}{errors}, 'the use-policy step accepts none';
    my $version = published_version($run);
    ok $version && $version->is_published, 'the offer publishes';
    is_deeply $version && $version->policies->{use}, { kind => 'none' }, 'carrying a none use policy';
};

subtest 'unknown or empty use value stays with an error' => sub {
    my $before = published_count();
    for my $value ( 'sometimes', 'NONE', '', undef, ['none'] ) {
        my $label = ref $value ? 'a list value' : !defined $value ? 'a missing value'
            : $value eq '' ? 'an empty value' : "'$value'";
        my ( $run, $result ) = walk( 'use-policy' => { use => $value } );
        ok $result->{'use-policy'}{errors}, "$label stays with an error";
        ok $result->{publish}{errors}, 'and publish refuses the run';
    }
    is published_count(), $before, 'nothing is published';
};

subtest 'skipped use choice publishes nothing' => sub {
    my $before = published_count();
    my ( $run, $result ) = walk( 'use-policy' => undef );
    ok $result->{publish}{errors}, 'publish stays with an error';
    like join( ' ', ( $result->{publish}{errors} // [] )->@* ), qr/use policy/i, 'asking for the use policy';
    ok !$run->data->{published_offer_version_id}, 'the run records no version';
    is published_count(), $before, 'and nothing is published';
};

subtest 'make up shape refused on day one' => sub {
    my $before = published_count();
    for my $value (qw( makeup make_up )) {
        my ( $run, $result ) = walk( 'use-policy' => { use => $value } );
        ok $result->{'use-policy'}{errors}, "'$value' stays with an error";
        ok !$run->data->{use_policy}, 'and the run records no use policy';
        ok $result->{publish}{errors}, 'and publish refuses the run';
    }
    is published_count(), $before, 'nothing is published';
};

subtest 'use value resubmitted at publish is ignored' => sub {
    for my $value (qw( optional_attendance makeup )) {
        my ( $run, $result ) = walk(
            'use-policy' => { use => 'none' },
            'publish'    => { use => $value, use_policy => { use => $value } },
        );
        my $version = published_version($run);
        ok $version && $version->is_published, "publish with use '$value' in its form still publishes";
        is_deeply $version && $version->policies->{use}, { kind => 'none' },
            'with the use policy the use-policy step recorded';
    }
};

done_testing;
