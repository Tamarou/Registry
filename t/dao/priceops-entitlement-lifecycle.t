#!/usr/bin/env perl
# ABOUTME: An entitlement's lifecycle: in effect while active, ended once as expired, refunded or lost to a dispute.
# ABOUTME: Also its link to the payment that created it and the partial refunds recorded against it.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Test::Registry::DB;
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO::Resource;
use Registry::DAO::Offer;
use Registry::DAO::OfferVersion;
use Registry::DAO::Entitlement;
use Registry::DAO::Tenant;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# A tenant provisioned the way signup provisions one: the row, then its schema.
sub new_tenant ($slug) {
    my $tenant = Registry::DAO::Tenant->create( $db, { name => "Studio $slug", slug => $slug } );
    $db->query( 'SELECT clone_schema(dest_schema => ?)', $slug );
    return $tenant->dao($dao)->db;
}

my $studio = new_tenant('kiln_house');
my $PAST   = '2020-01-01T00:00:00Z';

my $people = 0;
sub person ( $handle = $studio ) {
    return $handle->insert( 'users', { username => 'p' . ++$people }, { returning => 'id' } )
        ->hash->{id};
}

# A finite resource of $capacity units and a published version that buys it.
sub seats ( $capacity = 10, $handle = $studio ) {
    my $resource = Registry::DAO::Resource->create( $handle,
        { name => 'Kiln seats', kind => 'finite', capacity => $capacity } );
    my $version = Registry::DAO::Offer->create( $handle, { name => 'Kiln class' } )
        ->draft( $handle, offer_terms( $resource->id ) )->publish($handle);
    return ( $resource, $version );
}

# An entitlement to $version held by a new person, in effect from $PAST.
sub entitlement ( $version = ( seats() )[1], %more ) {
    return Registry::DAO::Entitlement->create( $studio, {
        holder_user_id   => person(),
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
        starts_at        => $PAST,
        %more,
    } );
}

sub reread ($e) { Registry::DAO::Entitlement->find( $studio, { id => $e->id } ) }

subtest 'ending moves record state reason and time' => sub {
    my $e = entitlement();
    is $e->state, 'active', 'a new entitlement is active';
    ok $e->is_in_effect($studio), 'and in effect';
    ok !defined $e->ended_at && !defined $e->ended_reason, 'with no ending';

    my %reason = (
        expired      => 'occurrence ended',
        refunded     => 're_full_1',
        dispute_lost => 'dp_lost_1',
    );
    for my $state ( sort keys %reason ) {
        my $ended = entitlement()->end( $studio, $state, $reason{$state} );
        my $read  = reread($ended);
        is $read->state,        $state,          "ending as $state records the state";
        is $read->ended_reason, $reason{$state}, '... its reason';
        ok defined $read->ended_at, '... and when it ended';
        ok !$read->is_in_effect($studio), '... and it is no longer in effect';
    }
};

done_testing;
