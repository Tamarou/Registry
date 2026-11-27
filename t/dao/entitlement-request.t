#!/usr/bin/env perl
# ABOUTME: A refund or change that needs approval is recorded as a request an admin decides once.
# ABOUTME: The first decision wins; the queue lists pending requests oldest first, against real Postgres.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Sessions qw( make_session session_offer );
use Registry::DAO;
use Registry::DAO::Family;
use Registry::DAO::Entitlement;
use Registry::DAO::EntitlementRequest;
use Registry::DAO::Workflow;

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;

my $made    = 0;
my $parent  = Test::Registry::Fixtures::create_user( $db, { username => 'er-parent' } );
my $admin   = Test::Registry::Fixtures::create_user( $db, { username => 'er-admin' } );
my $session = make_session($db);
my $version = session_offer( $db, $session );
my $offer   = $db->select( 'offers', 'name', { id => $version->offer_id } )->hash->{name};
my $flow    = Registry::DAO::Workflow->create( $db, { slug => 'er-flow', name => 'Request flow' } );

# A request for a new child's seat in the session, opened from a new run.
sub request ( $kind = 'refund' ) {
    my $child = Registry::DAO::Family->add_child( $db, $parent->id,
        { child_name => 'Child ' . ++$made, birth_date => '2018-01-01', grade => '3' } );
    my $e = Registry::DAO::Entitlement->grant( $db, {
        holder_family_member_id => $child->id,
        payer_user_id           => $parent->id,
        offer_version_id        => $version->id,
        payment_plan_id         => 'pay',
        starts_at               => 'now',
        resource_id             => $session->id,
        units                   => 1,
    } );
    return Registry::DAO::EntitlementRequest->open( $db, {
        entitlement_id  => $e->id,
        kind            => $kind,
        workflow_run_id => $flow->new_run($db)->id,
        outcome         => { amount_cents => 27000 + $made },
        requested_by    => $parent->id,
    } );
}

subtest 'an opened request is found by its run' => sub {
    my $r     = request();
    my $found = Registry::DAO::EntitlementRequest->for_run( $db, $r->workflow_run_id );
    is $found->id,    $r->id,    'the run finds its request';
    is $found->state, 'pending', 'pending';
    is $found->kind,  'refund',  'a refund';
    is_deeply $found->outcome, $r->outcome, 'with the computed outcome';
    ok !$found->decided_by && !$found->decided_at, 'and undecided';
    is Registry::DAO::EntitlementRequest->for_run( $db, $flow->new_run($db)->id ), undef,
        'a run without a request finds none';
};

subtest 'the first decision wins' => sub {
    my $r = request('change');
    ok $r->decide( $db, 'approved', $admin->id, 'fine' ), 'the first decision is taken';
    my $now = Registry::DAO::EntitlementRequest->for_run( $db, $r->workflow_run_id );
    is $now->state,      'approved', 'approved';
    is $now->decided_by, $admin->id, 'by the admin';
    ok $now->decided_at, 'with when';
    is $now->note, 'fine', 'and the note';
};

subtest 'pending lists only pending requests oldest first' => sub {
    my ( $old, $decided, $new ) = map { request() } 1 .. 3;
    $decided->decide( $db, 'declined', $admin->id, 'no' );
    my @mine = grep { my $id = $_->{id}; grep { $id eq $_ } $old->id, $decided->id, $new->id }
        Registry::DAO::EntitlementRequest->pending($db)->@*;
    is_deeply [ map { $_->{id} } @mine ], [ $old->id, $new->id ], 'the two pending, oldest first';
    is $mine[0]{child_name}, 'Child ' . ( $made - 2 ), 'with the child';
    is $mine[0]{offer_name}, $offer, 'the offer';
    is_deeply $mine[0]{outcome}, $old->outcome, 'and the outcome';
};

done_testing;
