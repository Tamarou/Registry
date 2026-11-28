#!/usr/bin/env perl
# ABOUTME: Each child on instalments gets its own Stripe schedule for parts two to n, recorded as rows of its entitlement.
# ABOUTME: Cancelling that schedule is recorded on the checkout charge before Stripe is asked, so Registry knows its own cancels.

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is ok is_deeply like subtest )];
defer { done_testing };

use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::PricingProbe ();
use Test::Registry::InstalmentCheckout qw( instalment_checkout );
use Registry::PriceOps::Instalments ();
use Registry::DAO::Payment;
use Registry::Service::Stripe;

my $t_db = Test::Registry::DB->new;
my $db   = $t_db->db->db;

my $seller = Test::Registry::Fixtures::platform_seller($db);
Test::Registry::PricingProbe::give_tenant_terms( $db, $seller, { rate => '0.025', name => 'Solo' } );

# Stripe's side of a schedule, recorded with what the database held when each
# call was made: $seen->() is read at every call. $on{schedule_made} runs
# once, inside the schedule create.
sub with_stripe ( $code, $seen = sub { undef }, %on ) {
    my @calls;
    my %status;
    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent = sub ( $s, $pi ) {
        push @calls, [ retrieve_payment_intent => $seen->() ];
        return { id => $pi, customer => 'cus_rows', payment_method => 'pm_rows' };
    };
    local *Registry::Service::Stripe::list_subscription_schedules = sub ( $s, $p ) {
        push @calls, [ list_subscription_schedules => $seen->() ];
        return { data => [] };
    };
    local *Registry::Service::Stripe::create_product = sub ( $s, $p ) {
        push @calls, [ create_product => $seen->() ];
        return { id => 'prod_rows' };
    };
    local *Registry::Service::Stripe::create_subscription_schedule = sub ( $s, $p ) {
        push @calls, [ create_subscription_schedule => $seen->() ];
        my $id = 'sub_sched_rows_' . scalar @calls;
        $status{$id} = 'not_started';
        if ( my $hook = delete $on{schedule_made} ) { $hook->() }
        return { id => $id };
    };
    local *Registry::Service::Stripe::retrieve_subscription_schedule = sub ( $s, $id ) {
        push @calls, [ retrieve_subscription_schedule => $seen->(), $id ];
        # Released by the studio: the subscription it made bills on alone.
        return { id => $id, status => 'released', released_subscription => "sub_of_$id" }
            if $on{released};
        return { id => $id, status => $status{$id} // 'active' };
    };
    local *Registry::Service::Stripe::retrieve_subscription = sub ( $s, $id ) {
        push @calls, [ retrieve_subscription => $seen->(), $id ];
        return { id => $id, status => $status{$id} // 'active' };
    };
    local *Registry::Service::Stripe::cancel_subscription = sub ( $s, $id, $p = {} ) {
        push @calls, [ cancel_subscription => $seen->(), $id, $p ];
        $status{$id} = 'canceled';
        return { id => $id, status => 'canceled' };
    };
    local *Registry::Service::Stripe::cancel_subscription_schedule = sub ( $s, $id, $p = {} ) {
        push @calls, [ cancel_subscription_schedule => $seen->(), $id, $p ];
        $status{$id} = 'canceled';
        return { id => $id, status => 'canceled' };
    };
    $code->();
    return \@calls;
}

sub rows ($c) {
    return $db->query( q{
        SELECT instalment_seq, instalment_count, amount_cents, due_date::text AS due_date,
               status, entitlement_id, stripe_schedule_id, user_id
          FROM payments WHERE entitlement_id = ? ORDER BY instalment_seq
    }, $c->{entitlement}->id )->hashes->to_array;
}

subtest 'rows two to n carry the entitlement and due dates' => sub {
    my $c = instalment_checkout( $db, slug => $seller, count => 4, cadence => 'weekly',
        price_cents => 10000, first_date => '2027-01-31' );
    my $schedule;
    with_stripe( sub { $schedule = $c->{payment}->schedule_instalments_for( $db, $c->{entitlement} ) } );

    my $dates = Registry::PriceOps::Instalments::due_dates( $c->{plan}, '2027-01-31' );
    is_deeply rows($c), [ map { {
        instalment_seq     => $_ + 1,
        instalment_count   => 4,
        amount_cents       => 2500,
        due_date           => $dates->[$_],
        status             => 'pending',
        entitlement_id     => $c->{entitlement}->id,
        stripe_schedule_id => $schedule,
        user_id            => $c->{parent},
    } } 1 .. 3 ], "parts two to four, owed by the payer on the child's entitlement and schedule";

    my $charge = Registry::DAO::Payment->find( $db, { id => $c->{payment}->id } );
    ok !defined $charge->instalment_seq && !defined $charge->stripe_schedule_id,
        'and the checkout charge carries no instalment columns';

    my $monthly = instalment_checkout( $db, slug => $seller, count => 3, cadence => 'monthly',
        first_date => '2027-01-31' );
    with_stripe( sub { $monthly->{payment}->schedule_instalments_for( $db, $monthly->{entitlement} ) } );
    is_deeply [ map { $_->{due_date} } rows($monthly)->@* ], [qw( 2027-02-28 2027-03-31 )],
        'monthly due dates anchor to the first date';
};

sub cancelled ($c) {
    return Registry::DAO::Payment->find( $db, { id => $c->{payment}->id } )->metadata->{cancelled_schedules};
}

subtest 'cancelling records the entitlement before asking stripe' => sub {
    my $c = instalment_checkout( $db, slug => $seller );
    my $schedule;
    with_stripe( sub { $schedule = $c->{payment}->schedule_instalments_for( $db, $c->{entitlement} ) } );

    my $calls = with_stripe(
        sub { Registry::DAO::Payment->find( $db, { id => $c->{payment}->id } )
                ->cancel_instalment_schedule( $db, $c->{entitlement} ) },
        sub { cancelled($c) } );

    my ($cancel) = grep { $_->[0] eq 'cancel_subscription_schedule' } @$calls;
    ok $cancel, 'Stripe is asked to cancel';
    is $cancel->[2], $schedule, "the child's own schedule";
    is_deeply $cancel->[1], [ $c->{entitlement}->id ],
        'with the entitlement already recorded in cancelled_schedules when it is asked';
    is $cancel->[3]{_idempotency_key}, 'cancel_schedule:' . $c->{entitlement}->id,
        'under a key named for the entitlement';
    is_deeply cancelled($c), [ $c->{entitlement}->id ], 'and the record stays';
};

subtest 'a second job run inserts nothing' => sub {
    my $c = instalment_checkout( $db, slug => $seller );
    my ( $first, $second );
    with_stripe( sub { $first = $c->{payment}->schedule_instalments_for( $db, $c->{entitlement} ) } );
    my $before = rows($c);

    # A retried job loads the charge afresh.
    my $calls = with_stripe( sub {
        $second = Registry::DAO::Payment->find( $db, { id => $c->{payment}->id } )
            ->schedule_instalments_for( $db, $c->{entitlement} );
    } );
    is $second, $first, 'it returns the recorded schedule';
    is_deeply rows($c), $before, 'and inserts no row';
    is_deeply $calls, [], 'without asking Stripe';
};

subtest 'a second cancel does nothing' => sub {
    my $c = instalment_checkout( $db, slug => $seller );
    my $calls = with_stripe( sub {
        $c->{payment}->schedule_instalments_for( $db, $c->{entitlement} );
        Registry::DAO::Payment->find( $db, { id => $c->{payment}->id } )
            ->cancel_instalment_schedule( $db, $c->{entitlement} ) for 1 .. 2;
    } );
    is scalar( grep { $_->[0] eq 'cancel_subscription_schedule' } @$calls ), 1,
        'Stripe is asked to cancel once';
    is_deeply cancelled($c), [ $c->{entitlement}->id ], 'and the entitlement is recorded once';
};

subtest 'a cancel before the schedule job runs leaves nothing to schedule' => sub {
    my $c = instalment_checkout( $db, slug => $seller );
    my ( $cancelled, $scheduled );
    my $calls = with_stripe( sub {
        $cancelled = $c->{payment}->cancel_instalment_schedule( $db, $c->{entitlement} );
        $scheduled = Registry::DAO::Payment->find( $db, { id => $c->{payment}->id } )
            ->schedule_instalments_for( $db, $c->{entitlement} );
    } );
    is $cancelled, undef, 'the cancel found no schedule';
    is_deeply cancelled($c), [ $c->{entitlement}->id ], 'but recorded the entitlement';
    is $scheduled, undef, 'so the schedule job, run after it, schedules nothing';
    is_deeply $calls, [], 'without asking Stripe';
    is_deeply rows($c), [], 'and records no instalment';
};

subtest 'an ended entitlement is not scheduled' => sub {
    my $c = instalment_checkout( $db, slug => $seller );
    $c->{entitlement}->end( $db, 'unpaid', 'dropped' );
    my $scheduled;
    my $calls = with_stripe( sub {
        $scheduled = $c->{payment}->schedule_instalments_for( $db, $c->{entitlement} );
    } );
    is $scheduled, undef, 'nothing is scheduled';
    is_deeply $calls, [], 'Stripe is not asked';
    is_deeply rows($c), [], 'and no instalment is recorded';
};

subtest 'a cancel waits for a schedule being made, then cancels it' => sub {
    my $c   = instalment_checkout( $db, slug => $seller );
    my $db2 = $t_db->db->db;
    my $waited;
    my $calls = with_stripe(
        sub { $c->{payment}->schedule_instalments_for( $db, $c->{entitlement} ) },
        sub { undef },
        schedule_made => sub {
            $db2->query(q{SET lock_timeout = '200ms'});
            eval { $c->{payment}->cancel_instalment_schedule( $db2, $c->{entitlement} ); 1 } or $waited = $@;
            $db2->query('RESET lock_timeout');
        } );
    like $waited, qr/lock timeout/, 'the cancel waited on the schedule being made';

    my $after = with_stripe( sub {
        $c->{payment}->cancel_instalment_schedule( $db2, $c->{entitlement} ) } );
    my ($cancel) = grep { $_->[0] eq 'cancel_subscription_schedule' } @$after;
    is $cancel->[2], rows($c)->[0]{stripe_schedule_id}, 'and once it was recorded, cancels it';
};

subtest 'a released schedule has its subscription cancelled and admins told' => sub {
    my $admin = Test::Registry::Fixtures::create_user( $db, { username => 'released-admin', user_type => 'admin' } );
    my $c = instalment_checkout( $db, slug => $seller );
    my $schedule;
    with_stripe( sub { $schedule = $c->{payment}->schedule_instalments_for( $db, $c->{entitlement} ) } );

    my $calls = with_stripe( sub {
        $c->{payment}->cancel_instalment_schedule( $db, $c->{entitlement} ) for 1 .. 2;
    }, sub { undef }, released => 1 );
    my @cancels = grep { $_->[0] =~ /\Acancel_/ } @$calls;
    is_deeply [ map { [ @$_[ 0, 2, 3 ] ] } @cancels ],
        [ [ cancel_subscription => "sub_of_$schedule",
            { _idempotency_key => 'cancel_subscription:' . $c->{entitlement}->id } ] ],
        'the subscription it released is cancelled, once, under a key named for the entitlement';

    my $told = $db->query( q{SELECT count(*) FROM notifications WHERE user_id = ? AND message LIKE ?},
        $admin->id, '%' . $c->{entitlement}->id . '%' )->array->[0];
    is $told, 1, 'and the admins are told once';
};

# Started on the checkout date, a schedule made on or after part two's due
# date could bill a missed period at once: nothing is made, and the studio
# arranges the rest by hand.
subtest 'a job run after due date two creates no schedule and alerts admins' => sub {
    my $admin = Test::Registry::Fixtures::create_user( $db, { username => 'late-admin', user_type => 'admin' } );
    my $c = instalment_checkout( $db, slug => $seller, first_date => '2026-01-01' );
    my $scheduled;
    my $calls = with_stripe( sub {
        $scheduled = $c->{payment}->schedule_instalments_for( $db, $c->{entitlement} );
    } );
    is $scheduled, undef, 'nothing is scheduled';
    is_deeply $calls, [], 'Stripe is not asked';
    is_deeply rows($c), [], 'and no instalment is recorded';

    my $child   = $db->select( 'family_members', 'child_name', { id => $c->{line}{family_member_id} } )->array->[0];
    my $session = $c->{session}->name;
    my $told = $db->select( 'notifications', [qw( subject message )], { user_id => $admin->id } )->hashes;
    is $told->size, 1, 'the admins are told';
    like $told->[0]{message}, qr/\Q$child\E.*\Q$session\E.*by hand/s, 'to arrange the child\'s instalments by hand';
};
