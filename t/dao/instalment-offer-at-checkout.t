#!/usr/bin/env perl
# ABOUTME: The cart offers instalments only when every priced line agrees on the same schedule.
# ABOUTME: A cart that offered them and then could not honour them is the defect #425 is about.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is ok is_deeply cmp_ok subtest diag )];
defer { done_testing };

use Test::Registry::DB;
use Registry::DAO::Payment;
use Registry::DAO::PricingPlan;

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
my $db   = $dao->db;

my $n = 0;
sub session_costing ( $cents, $schedule = undef ) {
    my $s = $dao->create( Session => {
        name => 'Camp ' . ++$n, start_date => '2026-06-01', end_date => '2026-08-31',
        status => 'published', capacity => 10, metadata => {},
    } );
    Registry::DAO::PricingPlan->create( $db, {
        session_id   => $s->id,
        plan_name    => "Plan $n",
        amount_cents => $cents,
        currency     => 'USD',
        pricing_configuration => $schedule ? { schedule => $schedule } : {},
    } );
    return $s;
}

sub cart_for ( @pairs ) {
    my ( @children, %selections );
    my $i = 0;
    for my $session (@pairs) {
        my $id = 'child-' . ++$i;
        push @children, { id => $id, first_name => "Child $i" };
        $selections{$id} = $session->id;
    }
    return Registry::DAO::Payment->calculate_enrollment_total( $db,
        { children => \@children, session_selections => \%selections } );
}

subtest 'a plan that declares no schedule offers only paying in full' => sub {
    my $info = cart_for( session_costing(30000) );
    is $info->{total}, 30000, 'the total is the plan price';

    my $options = $info->{schedule_options} // [];
    is scalar(@$options), 1, 'one way to pay';
    is $options->[0]{key}, 'full', 'and it is in full';
};

subtest 'a plan that declares one offers the choice, priced' => sub {
    my $info = cart_for( session_costing( 30000, { count => 3, cadence => 'monthly' } ) );

    my $options = $info->{schedule_options} // [];
    is scalar(@$options), 2, 'two ways to pay';
    is_deeply [ map { $_->{key} } @$options ], [ 'full', 'instalments' ],
        'in full, or in instalments';

    my ($plan) = grep { $_->{key} eq 'instalments' } @$options;
    is scalar( @{ $plan->{instalments} } ), 3, 'three charges';
    is $plan->{instalments}[0]{amount_cents}, 10000, 'the first is a third';

    my $sum = 0;
    $sum += $_->{amount_cents} for @{ $plan->{instalments} };
    is $sum, $info->{total},
        'and the instalments sum to exactly what paying in full costs';
};

# The rule, stated: a cart is one payment, so it cannot be half in instalments.
subtest 'two children on the same schedule split the cart, not each line' => sub {
    my $session = session_costing( 30000, { count => 3, cadence => 'monthly' } );
    my $info = cart_for( $session, $session );

    is $info->{total}, 60000, 'two children, two places';

    my ($plan) = grep { $_->{key} eq 'instalments' } @{ $info->{schedule_options} };
    ok $plan, 'instalments are offered' or return;
    is $plan->{instalments}[0]{amount_cents}, 20000,
        'each charge covers both children';
};

subtest 'a cart whose lines disagree is paid in full' => sub {
    my $instalments = session_costing( 30000, { count => 3, cadence => 'monthly' } );
    my $outright    = session_costing( 20000 );

    my $info = cart_for( $instalments, $outright );
    my $options = $info->{schedule_options} // [];

    is scalar(@$options), 1, 'only one way to pay';
    is $options->[0]{key}, 'full',
        'because one of the sessions does not offer instalments';

    # Not "instalments for the part that allows it". A cart is one charge and one
    # schedule; offering a mixture would mean two Stripe objects, two failure
    # modes and a parent statement nobody can read.
};

subtest 'a cart whose lines disagree about the COUNT is paid in full' => sub {
    my $three = session_costing( 30000, { count => 3, cadence => 'monthly' } );
    my $four  = session_costing( 20000, { count => 4, cadence => 'monthly' } );

    my $options = cart_for( $three, $four )->{schedule_options} // [];
    is scalar(@$options), 1, 'one way to pay';
    is $options->[0]{key}, 'full', 'three and four do not reconcile';
};

subtest 'a free cart is not offered instalments on nothing' => sub {
    my $free = session_costing( 0, { count => 3, cadence => 'monthly' } );
    my $options = cart_for($free)->{schedule_options} // [];

    is scalar(@$options), 1, 'one way to pay';
    is $options->[0]{key}, 'full', 'a total of zero is paid at once, trivially';
};

$t_db->cleanup_test_database;
