#!/usr/bin/env perl
# ABOUTME: Turning a child's instalment parts into Stripe subscription-schedule phases, cadence, fee and all.
# ABOUTME: Unequal amounts are the norm -- the odd cent lands on one charge, so phases must differ.

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is ok like is_deeply subtest note )];
defer { done_testing };

use Registry::DAO::Payment;
use Registry::PriceOps::RevenueShare;

sub phases_for ( @amounts ) {
    my $parts = [ map { { amount_cents => $_, due_date => '2026-06-01' } } @amounts ];
    return Registry::DAO::Payment::instalment_phases( $parts, 'usd', 'Summer Camp' );
}

subtest 'equal instalments collapse into one phase' => sub {
    my $phases = phases_for( 10000, 10000, 10000 );

    is scalar(@$phases), 1, 'one phase';
    is $phases->[0]{iterations},   3,     'charged three times';
    is $phases->[0]{unit_amount},  10000, 'at the same amount each time';

    # Not three phases of one. Stripe bills a phase per iteration, so collapsing
    # is not cosmetic -- it is the difference between one price object and three.
};

subtest 'the odd cent gets its own phase' => sub {
    my $phases = phases_for( 3333, 3333, 3334 );

    is scalar(@$phases), 2, 'two phases: the even share, then the remainder';
    is_deeply [ map { $_->{iterations} }  @$phases ], [ 2, 1 ], 'twice, then once';
    is_deeply [ map { $_->{unit_amount} } @$phases ], [ 3333, 3334 ], 'and the last differs';

    my $total = 0;
    $total += $_->{unit_amount} * $_->{iterations} for @$phases;
    is $total, 10000, 'the phases still bill the whole amount';
};

subtest 'a single charge is a single phase' => sub {
    my $phases = phases_for( 5000 );
    is scalar(@$phases), 1, 'one phase';
    is $phases->[0]{iterations}, 1, 'billed once';
};

# The whole request, as it goes to Stripe. This is the shape that decides where
# the money lands, so it is asserted rather than trusted.
subtest 'the schedule bills the customer and takes our fee' => sub {
    my $params = Registry::DAO::Payment::instalment_schedule_params( {
        customer           => 'cus_probe',
        payment_method     => 'pm_probe',
        revenue_share_pct  => 2.5,
        currency           => 'usd',
        description        => 'Summer Camp',
        product            => 'prod_probe',
        cadence            => 'monthly',
        entitlement_id     => 'ent_probe',
        instalments        => [
            { amount_cents => 3333, due_date => '2026-07-01' },
            { amount_cents => 3334, due_date => '2026-08-01' },
        ],
    } );

    is $params->{customer}, 'cus_probe', 'billed to the customer';
    is $params->{end_behavior}, 'cancel',
        'and it stops when the instalments are done, rather than renewing forever';

    # Direct charges: the schedule is made on the seller's own account, so the
    # money is already theirs. A transfer destination would send it nowhere new.
    ok !exists $params->{'default_settings[transfer_data][destination]'},
        'no transfer destination -- the charge is already on the seller account';
    is $params->{'default_settings[application_fee_percent]'}, 2.5,
        'with the revenue share taken as the application fee';
    is $params->{'default_settings[collection_method]'}, 'charge_automatically',
        'charged automatically -- nobody is present for instalment three';
    is $params->{'default_settings[default_payment_method]'}, 'pm_probe',
        'against the card saved at checkout';

    # First charge on the first due date, not now: instalment one was already
    # taken on-session at checkout, and this schedule covers what is left.
    like $params->{start_date}, qr/^\d+$/, 'start_date is an epoch second';
    ok $params->{start_date} > 0, 'and it is set';

    is $params->{'phases[0][items][0][price_data][unit_amount]'}, 3333,
        'the first phase bills the even share';
    is $params->{'phases[1][items][0][price_data][unit_amount]'}, 3334,
        'and the second the remainder';
    is $params->{'phases[0][items][0][price_data][recurring][interval]'}, 'month',
        'monthly';
    is $params->{'phases[0][items][0][price_data][recurring][interval_count]'}, 1,
        'every one month';
    is $params->{'phases[0][items][0][price_data][currency]'}, 'usd',
        'in the cart currency';

    # A product id, not inline product_data: Stripe refuses the latter inside a
    # schedule phase, which is the kind of thing only the real API tells you.
    is $params->{'phases[0][items][0][price_data][product]'}, 'prod_probe',
        'against a product the caller created';
};

# The cadence is the plan's, in every phase: an odd cent's phase bills on the
# same rhythm as the even shares before it.
sub params_for_cadence ( $cadence ) {
    return Registry::DAO::Payment::instalment_schedule_params( {
        customer          => 'cus_probe',
        payment_method    => 'pm_probe',
        revenue_share_pct => 2.5,
        currency          => 'usd',
        product           => 'prod_probe',
        cadence           => $cadence,
        entitlement_id    => 'ent_probe',
        instalments       => [
            { amount_cents => 3333, due_date => '2026-07-01' },
            { amount_cents => 3334, due_date => '2026-08-01' },
        ],
    } );
}

sub recurring ( $params ) {
    return [ map { [ $params->{"phases[$_][items][0][price_data][recurring][interval]"},
                     $params->{"phases[$_][items][0][price_data][recurring][interval_count]"} ] } 0, 1 ];
}

subtest 'weekly plans bill every week' => sub {
    is_deeply recurring( params_for_cadence('weekly') ), [ [ week => 1 ], [ week => 1 ] ],
        'each phase recurs every one week';
};

subtest 'quarterly plans bill every three months' => sub {
    is_deeply recurring( params_for_cadence('quarterly') ), [ [ month => 3 ], [ month => 3 ] ],
        'each phase recurs every three months, not every month';
};

subtest 'schedule params carry the entitlement id' => sub {
    is params_for_cadence('monthly')->{'metadata[entitlement_id]'}, 'ent_probe',
        "the schedule names the child's entitlement it bills for";
};

# Stripe bills a schedule from its start's day of the month, clamped to
# shorter months: started on the checkout date, Jan 31 bills Feb 28, Mar 31,
# Apr 30, as Instalments::due_dates says. Started on part two's date (Feb 28)
# it would bill Mar 28. So the schedule starts on the checkout date with a $0
# period for the part already paid, and every phase keeps that anchor.
subtest 'the schedule starts on the checkout date so month-end due dates are kept' => sub {
    my $params = Registry::DAO::Payment::instalment_schedule_params( {
        customer          => 'cus_probe',
        payment_method    => 'pm_probe',
        revenue_share_pct => 2.5,
        currency          => 'usd',
        product           => 'prod_probe',
        cadence           => 'monthly',
        entitlement_id    => 'ent_probe',
        first_date        => '2027-01-31',
        instalments       => [
            { amount_cents => 3333, due_date => '2027-02-28' },
            { amount_cents => 3334, due_date => '2027-03-31' },
        ],
    } );
    is $params->{start_date}, Registry::DAO::Payment::_epoch_for_date('2027-01-31'),
        'it starts on the checkout date, not the second due date';
    is_deeply [ map { [ $params->{"phases[$_][items][0][price_data][unit_amount]"},
                        $params->{"phases[$_][iterations]"},
                        $params->{"phases[$_][items][0][price_data][recurring][interval]"},
                        $params->{"phases[$_][items][0][price_data][recurring][interval_count]"} ] } 0 .. 2 ],
        [ [ 0, 1, month => 1 ], [ 3333, 1, month => 1 ], [ 3334, 1, month => 1 ] ],
        'a $0 period for the part paid at checkout, then parts two and three on the same interval';
    ok !( grep { /billing_cycle_anchor/ } keys %$params ), 'and no phase resets the anchor';
    ok !exists $params->{'phases[3][iterations]'}, 'three phases at most, however many parts';
};

subtest 'a tenant with no revenue share still gets its money' => sub {
    my $params = Registry::DAO::Payment::instalment_schedule_params( {
        customer          => 'cus_probe',
        payment_method    => 'pm_probe',
        revenue_share_pct => 0,
        currency          => 'usd',
        description       => 'Free Ride',
        product           => 'prod_probe',
        cadence           => 'monthly',
        entitlement_id    => 'ent_probe',
        instalments       => [ { amount_cents => 100, due_date => '2026-07-01' } ],
    } );

    ok !exists $params->{'default_settings[transfer_data][destination]'},
        'no transfer destination';
    ok !exists $params->{'default_settings[application_fee_percent]'},
        'and no application fee key at all, rather than a zero Stripe may reject';
};

# Everything above is a pure translation. Below, the real scheduling path
# against a real database, with only the Stripe HTTP calls replaced: they are
# recorded with the account the client was bound to, which is the subject.

use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::PricingProbe ();
use Test::Registry::InstalmentCheckout qw( instalment_checkout );
use Registry::PriceOps::PlatformTerms ();

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
my $db   = $dao->db;

my $seller = Test::Registry::Fixtures::platform_seller($db);
# The seller charges under Solo's 2.5%, as a tenant would.
Test::Registry::PricingProbe::give_tenant_terms( $db, $seller, { rate => '0.025', name => 'Solo' } );
my $plan_id = Registry::PriceOps::PlatformTerms::platform_terms_for_tenant( $db, $seller )->{id};
my $plan_pct = Registry::PriceOps::RevenueShare::revenue_share_fraction_for_tenant(
    $db, $seller ) * 100;

# A child's cart charge, paid, and the entitlement it made: $100 in three
# monthly parts, so the schedule covers 3333 and 3334.
sub checkout (%o) { instalment_checkout( $db, slug => $seller, %o ) }

# Runs $code with the four Stripe calls recorded rather than sent; listing
# the customer's schedules answers @$listed.
sub with_stripe_calls ( $code, $listed = [] ) {
    my @calls;
    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent = sub ( $s, $pi ) {
        push @calls, [ retrieve_payment_intent => $s->stripe_account, $pi ];
        return { id => $pi, customer => 'cus_one', payment_method => 'pm_one' };
    };
    local *Registry::Service::Stripe::list_subscription_schedules = sub ( $s, $p ) {
        push @calls, [ list_subscription_schedules => $s->stripe_account, $p ];
        return { data => $listed };
    };
    local *Registry::Service::Stripe::create_product = sub ( $s, $p ) {
        push @calls, [ create_product => $s->stripe_account, $p ];
        return { id => 'prod_one' };
    };
    local *Registry::Service::Stripe::create_subscription_schedule = sub ( $s, $p ) {
        push @calls, [ create_subscription_schedule => $s->stripe_account, $p ];
        return { id => 'sub_sched_' . scalar @calls };
    };
    $code->();
    return \@calls;
}

sub schedule ($c) { $c->{payment}->schedule_instalments_for( $db, $c->{entitlement} ) }

subtest 'schedule is made on the tenant account with fee percent and no transfer' => sub {
    my $c = checkout();
    my $calls = with_stripe_calls( sub { schedule($c) } );

    is_deeply [ map { $_->[0] } @$calls ],
        [qw( retrieve_payment_intent list_subscription_schedules
             create_product create_subscription_schedule )],
        'the intent, any schedule already made, the product and the schedule';
    is_deeply [ map { $_->[1] } @$calls ], [ ('acct_platform_test') x 4 ],
        'all on the seller account, where the customer and card live';

    my $params = $calls->[3][2];
    ok $plan_pct > 0, 'the seller is on a revenue-share plan';
    is $params->{'default_settings[application_fee_percent]'}, $plan_pct,
        'our share is the application fee percent';
    ok !( grep { /transfer_data/ } keys %$params ), 'and nothing is transferred';
    is $params->{customer}, 'cus_one', "billed to the checkout charge's customer";
    is $params->{'default_settings[default_payment_method]'}, 'pm_one', 'on the card it saved';
    is_deeply [ map { $params->{"phases[$_][items][0][price_data][unit_amount]"} } 0 .. 2 ],
        [ 0, 3333, 3334 ], 'a $0 period for part one, then parts two to n, from the charge line';
    is $params->{start_date},
        Registry::DAO::Payment::_epoch_for_date( $c->{line}{parts}[0]{due_date} ),
        'starting on the checkout date';
};

# Lets the Connect webhook tell an invoice from a schedule it has not recorded
# yet (retry) from one on the studio's own schedule (ignore).
subtest 'the schedule names the entitlement it bills for' => sub {
    my $c = checkout();
    my $calls = with_stripe_calls( sub { schedule($c) } );

    is $calls->[3][2]{'metadata[entitlement_id]'}, $c->{entitlement}->id, "the child's entitlement";
    is $calls->[2][2]{'metadata[entitlement_id]'}, $c->{entitlement}->id, 'and so does its product';
    is $calls->[3][2]{'phases[0][items][0][price_data][recurring][interval]'}, 'month',
        "and it bills on the plan's cadence";
};

subtest 'a quarterly plan is scheduled every three months' => sub {
    my $c = checkout( cadence => 'quarterly' );
    my $calls = with_stripe_calls( sub { schedule($c) } );
    is_deeply [ @{ $calls->[3][2] }{
        'phases[0][items][0][price_data][recurring][interval]',
        'phases[0][items][0][price_data][recurring][interval_count]' } ],
        [ month => 3 ], 'the plan stamped on the entitlement sets the cadence';
};

sub params_with_pct ( $pct ) {
    return Registry::DAO::Payment::instalment_schedule_params( {
        customer          => 'cus_probe',
        payment_method    => 'pm_probe',
        revenue_share_pct => $pct,
        currency          => 'usd',
        product           => 'prod_probe',
        cadence           => 'monthly',
        entitlement_id    => 'ent_probe',
        instalments       => [
            { amount_cents => 3333, due_date => '2026-07-01' },
            { amount_cents => 3334, due_date => '2026-08-01' },
        ],
    } );
}

subtest 'no transfer data anywhere in schedule params' => sub {
    my $params = params_with_pct(2.5);
    ok exists $params->{'phases[1][items][0][price_data][unit_amount]'},
        'the params carry more than one phase';
    is_deeply [ grep { /transfer_data/ } keys %$params ], [],
        'no transfer_data key in default_settings or any phase';
};

# Two places because Stripe refuses a third (t/stripe-live/schedule-fee-precision.t).
subtest 'fee percent has at most two decimals and zero is omitted' => sub {
    my $fee = sub ( $pct ) { params_with_pct($pct)->{'default_settings[application_fee_percent]'} };

    is $fee->(1.23456), '1.23', 'a long fraction is rounded to two places';
    is $fee->(2.875),   '2.88', 'a three-place plan rate is rounded, not refused by Stripe';
    is $fee->(0.01),    '0.01', 'a tiny one is written out, not as 1e-02';
    is $fee->( 0.029 * 100 ), '2.9', 'float noise does not reach Stripe';
    is $fee->(2.5), '2.5', 'and a plain one is sent as it is';
    is $fee->(10),  '10',  'and a whole one keeps its own zeros';
    like $fee->( $plan_pct ), qr/\A\d+(?:\.\d{1,2})?\z/,
        'the seeded plan rate fits the same shape';

    for my $zero ( 0, 0.0, '0.0', 0.004 ) {
        ok !exists params_with_pct($zero)->{'default_settings[application_fee_percent]'},
            "a percent of $zero is omitted";
    }
};

sub scheduled_rows ( $c ) {
    return $db->select( 'payments', 'count(*)', { entitlement_id => $c->{entitlement}->id } )->array->[0];
}

subtest 'seller without connect account gets no schedule' => sub {
    $db->query( 'UPDATE registry.tenants SET stripe_connect_account_id = NULL WHERE slug = ?',
        $seller );
    my $c = checkout();
    Test::Registry::Fixtures::platform_seller($db);

    require Registry::Job::InstalmentSchedule;
    my $died;
    my $calls = with_stripe_calls( sub {
        eval { Registry::Job::InstalmentSchedule->new->create_for( $db, $c->{entitlement} ); 1 }
            or $died = $@;
    } );

    like $died, qr/no seller Stripe account/, 'the job fails, so Minion retries it';
    is_deeply $calls, [], 'no intent lookup, product or schedule on any account';
    is scheduled_rows($c), 0, 'and no instalment is recorded as scheduled';
};

subtest 'a one-time line gets no schedule' => sub {
    my $c = checkout();
    $db->query( q{UPDATE payments SET metadata = jsonb_set(metadata, '{lines,0,kind}', '"one_time"')
                   WHERE id = ?}, $c->{payment}->id );
    my $paid = Registry::DAO::Payment->find( $db, { id => $c->{payment}->id } );
    my $calls = with_stripe_calls( sub {
        is $paid->schedule_instalments_for( $db, $c->{entitlement} ), undef, 'nothing to schedule';
    } );
    is_deeply $calls, [], 'and Stripe is not asked';
};

subtest 'rerun creates no second schedule' => sub {
    my $c = checkout();
    my $calls = with_stripe_calls( sub {
        schedule($c);
        # A retried job loads the row afresh rather than reusing the object.
        Registry::DAO::Payment->find( $db, { id => $c->{payment}->id } )
            ->schedule_instalments_for( $db, $c->{entitlement} );
    } );

    is scalar( grep { $_->[0] eq 'create_subscription_schedule' } @$calls ), 1,
        'one schedule at Stripe';
    is scheduled_rows($c), 2, 'and one row per remaining instalment';
};

# Stripe as it treats an Idempotency-Key: a key it has seen returns what the
# first request made, and a request without one makes a new object every time.
# Persists across runs, as Stripe's memory does across a crashed job. Every
# schedule made stays listable after its key is forgotten, as at Stripe.
my ( %stripe_by_key, @stripe_schedules );
my $stripe_serial = 0;
sub with_keyed_stripe ( $code, %on ) {
    my @made;
    my $make = sub ( $kind, $p ) {
        my $key = $p->{_idempotency_key};
        return $stripe_by_key{$key} if defined $key && $stripe_by_key{$key};
        my $obj = { id => $kind . '_' . ++$stripe_serial };
        push @made, [ $kind, $obj->{id} ];
        $stripe_by_key{$key} = $obj if defined $key;
        return $obj;
    };
    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent = sub ( $s, $pi ) {
        return { id => $pi, customer => 'cus_one', payment_method => 'pm_one' };
    };
    local *Registry::Service::Stripe::create_product = sub ( $s, $p ) {
        return $make->( prod => $p );
    };
    local *Registry::Service::Stripe::list_subscription_schedules = sub ( $s, $p ) {
        return { data => [ grep { $_->{customer} eq $p->{customer} } @stripe_schedules ] };
    };
    local *Registry::Service::Stripe::create_subscription_schedule = sub ( $s, $p ) {
        my $schedule = $make->( sub_sched => $p );
        # Listed as Stripe lists it: the fee under default_settings, one
        # entry per phase (its price an id, so no amount to read).
        push @stripe_schedules, { %$schedule, customer => $p->{customer},
            status => 'not_started', metadata => { entitlement_id => $p->{'metadata[entitlement_id]'} },
            default_settings => {
                application_fee_percent => $p->{'default_settings[application_fee_percent]'} },
            phases => [ map { { items => [ { price => 'price_x', quantity => 1 } ] } }
                grep { /\Aphases\[\d+\]\[iterations\]\z/ } keys %$p ] }
            unless grep { $_->{id} eq $schedule->{id} } @stripe_schedules;
        # Once: the hook may itself schedule, and must not fire inside itself.
        if ( my $hook = delete $on{schedule_made} ) { $hook->() }
        return $schedule;
    };
    local *Registry::Service::Stripe::retrieve_subscription_schedule = sub ( $s, $id ) {
        my ($at) = grep { $_->{id} eq $id } @stripe_schedules;
        return $at;
    };
    local *Registry::Service::Stripe::cancel_subscription_schedule = sub ( $s, $id, $p = {} ) {
        my ($at) = grep { $_->{id} eq $id } @stripe_schedules;
        $at->{status} = 'canceled';
        return $at;
    };
    $code->();
    return [ grep { $_->[0] eq 'sub_sched' } @made ];
}

sub recorded_schedule ( $c ) {
    return $db->select( 'payments', 'DISTINCT stripe_schedule_id',
        { entitlement_id => $c->{entitlement}->id } )->arrays->flatten->to_array;
}

subtest 'a retried job after create-then-crash makes one schedule' => sub {
    my $c = checkout();

    # Stripe makes the schedule; the job dies before its COMMIT, as a worker
    # killed mid-request or a lost response would leave it.
    my $crashed;
    my $made = with_keyed_stripe(
        sub { eval { schedule($c); 1 } or $crashed = $@ },
        schedule_made => sub { die "worker lost\n" },
    );
    is $crashed, "worker lost\n", 'the first run died after Stripe made the schedule';
    is scalar @$made, 1, 'leaving one schedule at Stripe';
    is scheduled_rows($c), 0, 'and nothing recorded here';

    require Registry::Job::InstalmentSchedule;
    my $retried = with_keyed_stripe( sub {
        Registry::Job::InstalmentSchedule->new->create_for( $db, $c->{entitlement} );
    } );
    is_deeply $retried, [], 'the retry makes no second schedule at Stripe';
    is_deeply recorded_schedule($c), [ $made->[0][1] ], 'and records the one the first run made';
    is scheduled_rows($c), 2, 'with one row per remaining instalment';
};

subtest 'a late run whose key has expired reuses the existing schedule and makes no second one' => sub {
    my $c = checkout();

    my $crashed;
    my $made = with_keyed_stripe(
        sub { eval { schedule($c); 1 } or $crashed = $@ },
        schedule_made => sub { die "worker lost\n" },
    );
    is scalar @$made, 1, 'a crash before COMMIT leaves one schedule at Stripe';

    # More than 24 hours on, Stripe has forgotten every key, and the run is a
    # first attempt: a job queued afresh, not a retry.
    %stripe_by_key = ();
    require Registry::Job::InstalmentSchedule;
    my $late = with_keyed_stripe( sub {
        Registry::Job::InstalmentSchedule->new->create_for( $db, $c->{entitlement} );
    } );
    is_deeply $late, [], 'the late run makes no second schedule';
    is_deeply recorded_schedule($c), [ $made->[0][1] ], 'and records the one already at Stripe';
    is scheduled_rows($c), 2, 'with one row per remaining instalment';
};

# The schedule is on the seller's own account, so the seller can make one
# naming this entitlement. Metadata proves nothing; adopted only when it
# bills our fee in the phases we would send.
sub seller_made_schedule_is_refused ( $listed_fee, $listed_phases ) {
    my $c = checkout();
    my @warnings;
    my $calls = do {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        with_stripe_calls( sub { schedule($c) }, [ {
            id               => "sub_sched_seller\n",
            status           => 'not_started',
            metadata         => { entitlement_id => $c->{entitlement}->id },
            default_settings => { application_fee_percent => $listed_fee },
            phases           => $listed_phases,
        } ] );
    };
    is scalar( grep { $_->[0] eq 'create_subscription_schedule' } @$calls ), 1,
        'Registry makes its own schedule';
    like recorded_schedule($c)->[0], qr/\Asub_sched_\d+\z/, 'and records that one';
    is scalar @warnings, 1, 'with one warning';
    like $warnings[0], qr/not adopting .*sub_sched_seller\\x\{a\}/,
        'naming the schedule, escaped';
}

subtest 'a listed schedule naming this entitlement but taking no fee is not adopted' => sub {
    seller_made_schedule_is_refused( undef, [ {}, {}, {} ] );
};

subtest 'a listed schedule naming this entitlement with the wrong phases is not adopted' => sub {
    seller_made_schedule_is_refused( $plan_pct, [ {} ] );
};

subtest 'two jobs for one entitlement make one schedule' => sub {
    my $c = checkout();

    # Both jobs load the charge before either has scheduled, as two jobs
    # queued at once do.
    my $db2   = $t_db->db->db;
    my $other = Registry::DAO::Payment->find( $db2, { id => $c->{payment}->id } );

    # The second job starts while the first is mid-flight at Stripe. It must
    # wait for the first rather than race it; a short lock_timeout turns that
    # wait into an error this test can see.
    my $second;
    my $made = with_keyed_stripe(
        sub { schedule($c) },
        schedule_made => sub {
            $db2->query(q{SET lock_timeout = '200ms'});
            eval { $other->schedule_instalments_for( $db2, $c->{entitlement} ); 1 } or $second = $@;
            $db2->query('RESET lock_timeout');
        },
    );
    like $second, qr/lock timeout/, 'the second job waited on the first';
    is scalar @$made, 1, 'one schedule while both ran';

    # Once the first has committed, the second finds the schedule rather
    # than making another.
    my $id;
    my $again = with_keyed_stripe( sub { $id = $other->schedule_instalments_for( $db2, $c->{entitlement} ) } );
    is_deeply $again, [], 'the second job makes no schedule afterwards';
    is $id, $made->[0][1], 'and reports the first one';
    is scheduled_rows($c), 2, 'and adds no rows';
};

subtest 'schedule uses the account the checkout charge was made on' => sub {
    my $c = checkout();
    $db->query( q{UPDATE registry.tenants SET stripe_connect_account_id = 'acct_moved'
                   WHERE slug = ?}, $seller );

    my $calls = with_stripe_calls( sub { schedule($c) } );
    Test::Registry::Fixtures::platform_seller($db);

    is scalar @$calls, 4, 'the intent, the schedules listed, the product and the schedule';
    is_deeply [ map { $_->[1] } @$calls ], [ ('acct_platform_test') x 4 ],
        'all on the account the customer was charged on, not the new one';

    # A later refund of instalment two goes through that row's own client, so
    # the row must carry the account too or it dies with no account to refund on.
    my $later = $db->query( q{
        SELECT metadata->>'stripe_account_id' FROM payments
         WHERE entitlement_id = ? ORDER BY instalment_seq
    }, $c->{entitlement}->id )->arrays->flatten->to_array;
    is_deeply $later, [ ('acct_platform_test') x 2 ],
        'and the later instalment rows carry that same account';
};

# A later instalment's fee is recorded when its invoice is paid, months on, and
# must name the plan that priced the schedule -- not whatever the tenant is on.
subtest 'later instalment rows carry the plan snapshotted on the checkout charge' => sub {
    my $c = checkout();
    is $c->{payment}->metadata->{platform_offer_version_id}, $plan_id,
        'the checkout charge snapshotted the platform offer version';

    with_stripe_calls( sub { schedule($c) } );

    my $later = $db->query( q{
        SELECT metadata->>'platform_offer_version_id' FROM payments
         WHERE entitlement_id = ? ORDER BY instalment_seq
    }, $c->{entitlement}->id )->arrays->flatten->to_array;
    is_deeply $later, [ ($plan_id) x 2 ], 'and so does each later row';
};

# The product and schedule creates carry Idempotency-Keys, so a retry after a
# crash must send what the first run sent; a rate read afresh would differ
# after a plan change and Stripe would answer with an idempotency error.
subtest 'the instalment schedule uses the rate snapshotted on the checkout charge' => sub {
    my $c = checkout();
    my $calls;
    Test::Registry::PricingProbe::with_tenant_plan( $db, $seller, { rate => 0 }, sub {
        is Registry::PriceOps::RevenueShare::revenue_share_fraction_for_tenant( $db, $seller ), 0,
            'the seller has since moved to terms with no revenue share';
        $calls = with_stripe_calls( sub { schedule($c) } );
    } );

    is $calls->[3][2]{'default_settings[application_fee_percent]'}, $plan_pct,
        'the schedule still takes the rate the checkout charge was quoted at';
};

# The product and schedule creates carry keys named for the entitlement, so a
# retry must send what the first run sent, whatever the offer is called now.
subtest 'a retry sends the name the first run stamped, not the offer name now' => sub {
    my $c = checkout();
    my $first = with_stripe_calls( sub {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_subscription_schedule = sub ( $s, $p ) { die "Connect timeout\n" };
        eval { schedule($c); 1 };
    } );
    my ($name) = map { $_->[2]{name} } grep { $_->[0] eq 'create_product' } @$first;
    ok $name, 'the first run named the product';

    $db->update( 'offers', { name => 'Renamed since' }, { id => $c->{version}->offer_id } );
    my $retry = with_stripe_calls( sub { schedule($c) } );
    is_deeply [ map { $_->[2]{name} } grep { $_->[0] eq 'create_product' } @$retry ], [$name],
        'the retry names the product as the first run did';
    is $retry->[3][2]{'phases[0][items][0][price_data][product]'}, 'prod_one', 'and bills against it';
};

sub status_at_stripe ( $id ) { ( map { $_->{status} } grep { $_->{id} eq $id } @stripe_schedules )[0] }

# Attempt one makes the schedule at Stripe and dies before its COMMIT: no
# row records it. Whatever then stops the retry must still cancel it, or
# Stripe charges parts two to n for a child who has gone.
sub made_then_crashed ( $c ) {
    my $made = with_keyed_stripe(
        sub { eval { schedule($c); 1 } },
        schedule_made => sub { die "worker lost\n" },
    );
    is scalar @$made, 1, 'attempt one left a schedule at Stripe';
    is scheduled_rows($c), 0, 'with nothing recorded';
    return $made->[0][1];
}

subtest 'a schedule an attempt made before it died is cancelled when the family drops' => sub {
    my $c  = checkout();
    my $at = made_then_crashed($c);

    with_keyed_stripe( sub {
        Registry::DAO::Payment->find( $db, { id => $c->{payment}->id } )
            ->cancel_instalment_schedule( $db, $c->{entitlement} );
    } );
    is status_at_stripe($at), 'canceled', 'the cancel finds it at Stripe and cancels it';

    my $retried;
    my $made = with_keyed_stripe( sub {
        $retried = Registry::Job::InstalmentSchedule->new->create_for( $db, $c->{entitlement} );
    } );
    is $retried, undef, 'the retry schedules nothing';
    is_deeply $made, [], 'and makes nothing at Stripe';
    is scheduled_rows($c), 0, 'or here';
};

subtest 'a retry that finds the entitlement ended cancels the schedule an attempt made' => sub {
    my $c  = checkout();
    my $at = made_then_crashed($c);
    $c->{entitlement}->end( $db, 'unpaid', 'dropped' );
    with_keyed_stripe( sub { Registry::Job::InstalmentSchedule->new->create_for( $db, $c->{entitlement} ) } );
    is status_at_stripe($at), 'canceled', 'the schedule at Stripe is cancelled';
    is scheduled_rows($c), 0, 'and nothing is recorded';
};

subtest 'a retry past due date two cancels the schedule an attempt made' => sub {
    my $c  = checkout();
    my $at = made_then_crashed($c);
    $db->query( q{UPDATE payments SET metadata = jsonb_set(metadata, '{lines,0,parts,1,due_date}', '"2000-01-01"')
                   WHERE id = ?}, $c->{payment}->id );
    with_keyed_stripe( sub {
        Registry::DAO::Payment->find( $db, { id => $c->{payment}->id } )
            ->schedule_instalments_for( $db, $c->{entitlement} );
    } );
    is status_at_stripe($at), 'canceled', 'the schedule at Stripe is cancelled';
    is scheduled_rows($c), 0, 'and nothing is recorded';
};
