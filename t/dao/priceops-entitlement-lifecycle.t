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
use Registry::PriceOps::Hold;

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
sub entitlement ( $version = undef, %more ) {
    $version //= ( seats() )[1];
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

# A completed payment of $cents in $handle's schema; returns its id.
sub payment ( $cents, $handle = $studio ) {
    return $handle->insert( 'payments',
        { user_id => person($handle), amount_cents => $cents, status => 'completed' },
        { returning => 'id' } )->hash->{id};
}

subtest 'entitlement records its payment and share' => sub {
    my $paid = payment(5000);
    my $e    = entitlement( undef, payment_id => $paid, payment_share_cents => 2000 );
    is $e->payment_id,          $paid, 'it records the payment that created it';
    is $e->payment_share_cents, 2000,  'and its share of that payment';
    is $e->payment($studio)->id, $paid, 'and reads that payment back';

    my $tenant = Registry::DAO::Tenant->create( $db, { name => 'Solo Studio', slug => 'solo_studio' } );
    my ( undef, $solo ) = seats( 1, $db );
    my $free = Registry::DAO::Entitlement->create( $db, {
        holder_tenant_id => $tenant->id,
        offer_version_id => $solo->id,
        payment_plan_id  => 'pay',
        starts_at        => $PAST,
    } );
    ok !defined $free->payment_id && !defined $free->payment_share_cents,
        'a percentage-of-sales Solo entitlement no payment created has an empty link';
    ok !defined $free->payment($db), 'and reads no payment';
};

subtest 'payment finds the entitlements it created' => sub {
    my ( undef, $version ) = seats();
    my $cart  = payment(4000);
    my @made  = map { entitlement( $version, payment_id => $cart, payment_share_cents => 2000 ) } 1 .. 2;
    entitlement( $version, payment_id => payment(2000), payment_share_cents => 2000 );

    is_deeply [ sort map { $_->id } Registry::DAO::Entitlement->created_by_payment( $studio, $cart ) ],
        [ sort map { $_->id } @made ], 'a payment that created two entitlements finds both and no other';
};

my $SOON = do {
    my @t = gmtime( time + 3600 );
    sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, @t[ 3, 2, 1, 0 ];
};

# A grant of $units units of $version's resource to a new person.
sub granted ( $version, $units, %more ) {
    return Registry::DAO::Entitlement->grant( $studio, {
        holder_user_id   => person(),
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
        resource_id      => $version->resource_id,
        units            => $units,
        starts_at        => $PAST,
        %more,
    } );
}

subtest 'ended entitlement frees its units' => sub {
    my ( $resource, $version ) = seats(4);
    my $refunded = granted( $version, 2 );
    my $future   = granted( $version, 1, starts_at => '2099-01-01T00:00:00Z' );
    my $skewed   = granted( $version, 1 );
    is $resource->free_units($studio), 0, 'four units held fill the resource';

    $refunded->end( $studio, 'refunded', 're_units_1' );
    is $resource->free_units($studio), 2, 'a refunded entitlement frees its two units';
    $future->end( $studio, 'refunded', 're_units_2' );
    is $resource->free_units($studio), 3, 'one refunded before it began frees its unit';
    # Stripe's clock may run ahead of ours: ended is ended, whatever the time.
    $skewed->end( $studio, 'dispute_lost', 'dp_units_1', $SOON );
    is $resource->free_units($studio), 4, 'one ended at a time still ahead frees its unit now';
    ok granted( $version, 4 ), 'so all four can be granted again';
};

# Is $e among the entitlements in effect at $t by the class lookup?
sub listed_at ( $e, $t ) {
    return scalar grep { $_->id eq $e->id } Registry::DAO::Entitlement->in_effect_at( $studio, $t );
}

my $INSIDE = '2021-06-01T00:00:00Z';    # inside every period that starts at $PAST

subtest 'in effect iff period covers now and state active' => sub {
    my ( $resource, $version ) = seats(10);
    my $active = granted( $version, 1 );
    my $over   = granted( $version, 1, ends_at => '2021-01-01T00:00:00Z' );
    my $later  = granted( $version, 1, starts_at => '2099-01-01T00:00:00Z' );
    my $ended  = granted( $version, 1 );
    $ended = $ended->end( $studio, 'dispute_lost', 'dp_pred_1', $SOON );

    ok $active->is_in_effect($studio), 'active and covering now: in effect';
    ok !$over->is_in_effect($studio),  'active but its period is over: not';
    ok !$later->is_in_effect($studio), 'active but not yet begun: not';
    ok !$ended->is_in_effect($studio), 'covering now but ended: not';

    ok listed_at( $active, $INSIDE ) && !listed_at( $ended, $INSIDE ),
        'the in-effect lookup answers by the same rule';
    my %holds = map { $_ => Registry::DAO::Entitlement->holds_unit_of( $studio, $_->holder_user_id,
        $resource->id ) } $active, $ended;
    ok $holds{$active}, 'the holder check finds the active holder';
    ok !$holds{$ended}, 'and not the ended one';
};

subtest 'refunded entitlement not in effect inside its period' => sub {
    my $e = entitlement();
    ok listed_at( $e, $INSIDE ), 'an open entitlement is in effect inside its period';
    $e->end( $studio, 'refunded', 're_inside_1' );
    ok !listed_at( $e, $INSIDE ), 'refunded, it is not in effect at a time inside that period';
    ok !reread($e)->is_in_effect( $studio, $INSIDE ), 'by either form of the predicate';
};

subtest 'ending sets state and closes period together' => sub {
    my $period = sub ($e) {
        $studio->query( q{SELECT isempty(in_effect) AS empty, upper(in_effect) = ended_at AS closed,
                                 upper(in_effect) AS upper FROM entitlements WHERE id = ?}, $e->id )->hash;
    };
    my $open = entitlement()->end( $studio, 'expired', 'occurrence ended' );
    ok $period->($open)->{closed}, 'ending an open period closes it at the ending time';

    my $future = entitlement( undef, starts_at => '2099-01-01T00:00:00Z' )
        ->end( $studio, 'refunded', 're_close_1' );
    ok $period->($future)->{empty}, 'ending one before it began leaves an empty period';

    my $over = entitlement( undef, ends_at => '2021-01-01T00:00:00Z' )
        ->end( $studio, 'refunded', 're_close_2' );
    like $period->($over)->{upper}, qr/^2021-01-01/, 'one whose period was already over keeps its end';

    my $raw = entitlement();
    throws_ok {
        $studio->query( q{UPDATE entitlements SET state = 'refunded', ended_at = now(),
                          ended_reason = 're_raw' WHERE id = ?}, $raw->id )
    } qr/entitlements_ending_check/, 'ending without closing the period is refused';
    throws_ok {
        $studio->query( q{UPDATE entitlements SET in_effect = 'empty' WHERE id = ?}, $raw->id )
    } qr/entitlements_in_effect_check/, 'and so is emptying an active period';
    is reread($raw)->state, 'active', 'leaving it active';
};

subtest 'capacity counts active and held units never ended' => sub {
    my ( $resource, $version ) = seats(10);
    granted( $version, 2 );
    granted( $version, 1, starts_at => '2099-01-01T00:00:00Z' );
    granted( $version, 3 )->end( $studio, 'refunded', 're_cap_1' );
    granted( $version, 1, ends_at => '2021-01-01T00:00:00Z' );
    my $workflow = $studio->insert( 'workflows', { slug => 'cap-run', name => 'Cap run' },
        { returning => 'id' } )->hash->{id};
    Registry::PriceOps::Hold->place( $studio, {
        resource_id     => $resource->id,
        units           => 2,
        workflow_run_id => $studio->insert( 'workflow_runs', { workflow_id => $workflow },
            { returning => 'id' } )->hash->{id},
        expires_at      => \"now() + interval '10 minutes'",
    } );
    is $resource->free_units($studio), 5,
        'two active, one future-dated and two held count; three ended and one over do not';
};

done_testing;
