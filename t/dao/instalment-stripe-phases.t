#!/usr/bin/env perl
# ABOUTME: Turning an instalment list into Stripe subscription-schedule phases, fee and all.
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
    # taken on-session at enrolment, and this schedule covers what is left.
    like $params->{start_date}, qr/^\d+$/, 'start_date is an epoch second';
    ok $params->{start_date} > 0, 'and it is set';

    is $params->{'phases[0][items][0][price_data][unit_amount]'}, 3333,
        'the first phase bills the even share';
    is $params->{'phases[1][items][0][price_data][unit_amount]'}, 3334,
        'and the second the remainder';
    is $params->{'phases[0][items][0][price_data][recurring][interval]'}, 'month',
        'monthly';
    is $params->{'phases[0][items][0][price_data][currency]'}, 'usd',
        'in the cart currency';

    # A product id, not inline product_data: Stripe refuses the latter inside a
    # schedule phase, which is the kind of thing only the real API tells you.
    is $params->{'phases[0][items][0][price_data][product]'}, 'prod_probe',
        'against a product the caller created';
};

subtest 'a tenant with no revenue share still gets its money' => sub {
    my $params = Registry::DAO::Payment::instalment_schedule_params( {
        customer          => 'cus_probe',
        payment_method    => 'pm_probe',
        revenue_share_pct => 0,
        currency          => 'usd',
        description       => 'Free Ride',
        product           => 'prod_probe',
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

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
my $db   = $dao->db;

my $seller = Test::Registry::Fixtures::platform_seller($db);
my $plan_id = $db->query(q{
    SELECT id FROM registry.pricing_plans
     WHERE plan_scope = 'tenant' AND pricing_model_type = 'percentage'
       AND metadata->>'default' IS DISTINCT FROM 'true'
     ORDER BY created_at LIMIT 1
})->hash->{id};
$db->query( 'UPDATE registry.tenants SET platform_pricing_plan_id = ? WHERE slug = ?',
    $plan_id, $seller );
my $plan_pct = Registry::PriceOps::RevenueShare::revenue_share_fraction_for_tenant(
    $db, $seller ) * 100;

my $parent = $dao->create( User => { username => 'schedule_parent', user_type => 'parent' } );

# Instalment one, paid, as checkout leaves it.
sub first_instalment () {
    return Registry::DAO::Payment->create( $db, {
        user_id                  => $parent->id,
        amount_cents             => 3333,
        status                   => 'completed',
        instalment_seq           => 1,
        instalment_count         => 3,
        stripe_payment_intent_id => 'pi_first',
        metadata => {
            tenant_slug     => $seller,
            instalment_plan => [
                { amount_cents => 3333, due_date => '2026-06-01' },
                { amount_cents => 3333, due_date => '2026-07-01' },
                { amount_cents => 3334, due_date => '2026-08-01' },
            ],
        },
    } );
}

# Runs $code with the three Stripe calls recorded rather than sent.
sub with_stripe_calls ( $code ) {
    my @calls;
    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent = sub ( $s, $pi ) {
        push @calls, [ retrieve_payment_intent => $s->stripe_account, $pi ];
        return { id => $pi, customer => 'cus_one', payment_method => 'pm_one' };
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

subtest 'schedule is made on the tenant account with fee percent and no transfer' => sub {
    my $payment = first_instalment();
    my $calls = with_stripe_calls( sub { $payment->schedule_remaining_instalments($db) } );

    is_deeply [ map { $_->[0] } @$calls ],
        [qw( retrieve_payment_intent create_product create_subscription_schedule )],
        'the intent, the product and the schedule';
    is_deeply [ map { $_->[1] } @$calls ], [ ('acct_platform_test') x 3 ],
        'all on the seller account, where the customer and card live';

    my $params = $calls->[2][2];
    ok $plan_pct > 0, 'the seller is on a revenue-share plan';
    is $params->{'default_settings[application_fee_percent]'}, $plan_pct,
        'our share is the application fee percent';
    ok !( grep { /transfer_data/ } keys %$params ), 'and nothing is transferred';
};

# Lets the Connect webhook tell an invoice from a schedule it has not recorded
# yet (retry) from one on the studio's own schedule (ignore).
subtest 'the schedule names the payment it bills for' => sub {
    my $payment = first_instalment();
    my $calls = with_stripe_calls( sub { $payment->schedule_remaining_instalments($db) } );

    is $calls->[2][2]{'metadata[payment_id]'}, $payment->id, "instalment one's id";
};

sub params_with_pct ( $pct ) {
    return Registry::DAO::Payment::instalment_schedule_params( {
        customer          => 'cus_probe',
        payment_method    => 'pm_probe',
        revenue_share_pct => $pct,
        currency          => 'usd',
        product           => 'prod_probe',
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

subtest 'seller without connect account gets no schedule' => sub {
    $db->query( 'UPDATE registry.tenants SET stripe_connect_account_id = NULL WHERE slug = ?',
        $seller );
    my $payment = first_instalment();
    Test::Registry::Fixtures::platform_seller($db);

    require Registry::Job::InstalmentSchedule;
    my $died;
    my $calls = with_stripe_calls( sub {
        eval { Registry::Job::InstalmentSchedule->new->create_for( $db, $payment ); 1 }
            or $died = $@;
    } );

    like $died, qr/no seller Stripe account/, 'the job fails, so Minion retries it';
    is_deeply $calls, [], 'no intent lookup, product or schedule on any account';

    my $row = Registry::DAO::Payment->find( $db, { id => $payment->id } );
    ok !$row->stripe_schedule_id, 'no schedule is recorded';
    is $db->query( q{SELECT count(*) FROM payments WHERE metadata->>'instalment_of' = ?},
        $payment->id )->array->[0], 0, 'and the remaining instalments are not marked scheduled';
};

subtest 'rerun creates no second schedule' => sub {
    my $payment = first_instalment();
    my $calls = with_stripe_calls( sub {
        $payment->schedule_remaining_instalments($db);
        # A retried job loads the row afresh rather than reusing the object.
        Registry::DAO::Payment->find( $db, { id => $payment->id } )
            ->schedule_remaining_instalments($db);
    } );

    is scalar( grep { $_->[0] eq 'create_subscription_schedule' } @$calls ), 1,
        'one schedule at Stripe';
    is $db->query( q{SELECT count(*) FROM payments WHERE metadata->>'instalment_of' = ?},
        $payment->id )->array->[0], 2, 'and one row per remaining instalment';
};

# Stripe as it treats an Idempotency-Key: a key it has seen returns what the
# first request made, and a request without one makes a new object every time.
# Persists across runs, as Stripe's memory does across a crashed job.
my %stripe_by_key;
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
    local *Registry::Service::Stripe::create_subscription_schedule = sub ( $s, $p ) {
        my $schedule = $make->( sub_sched => $p );
        # Once: the hook may itself schedule, and must not fire inside itself.
        if ( my $hook = delete $on{schedule_made} ) { $hook->() }
        return $schedule;
    };
    $code->();
    return [ grep { $_->[0] eq 'sub_sched' } @made ];
}

sub scheduled_rows ( $payment ) {
    return $db->query( q{SELECT count(*) FROM payments WHERE metadata->>'instalment_of' = ?},
        $payment->id )->array->[0];
}

subtest 'a retried job after create-then-crash makes one schedule' => sub {
    my $payment = first_instalment();

    # Stripe makes the schedule; the job dies before its COMMIT, as a worker
    # killed mid-request or a lost response would leave it.
    my $crashed;
    my $made = with_keyed_stripe(
        sub {
            eval { $payment->schedule_remaining_instalments($db); 1 } or $crashed = $@;
        },
        schedule_made => sub { die "worker lost\n" },
    );
    is $crashed, "worker lost\n", 'the first run died after Stripe made the schedule';
    is scalar @$made, 1, 'leaving one schedule at Stripe';
    is scheduled_rows($payment), 0, 'and nothing recorded here';

    require Registry::Job::InstalmentSchedule;
    my $retried = with_keyed_stripe( sub {
        Registry::Job::InstalmentSchedule->new->create_for( $db,
            Registry::DAO::Payment->find( $db, { id => $payment->id } ) );
    } );
    is_deeply $retried, [], 'the retry makes no second schedule at Stripe';

    my $row = Registry::DAO::Payment->find( $db, { id => $payment->id } );
    is $row->stripe_schedule_id, $made->[0][1], 'and records the one the first run made';
    is scheduled_rows($payment), 2, 'with one row per remaining instalment';
};

subtest 'two jobs for one payment make one schedule' => sub {
    my $payment = first_instalment();

    # Both jobs load the row before either has scheduled, as two jobs queued by
    # near-simultaneous success events do.
    my $db2   = $t_db->db->db;
    my $other = Registry::DAO::Payment->find( $db2, { id => $payment->id } );

    # The second job starts while the first is mid-flight at Stripe. It must
    # wait for the first rather than race it; a short lock_timeout turns that
    # wait into an error this test can see.
    my $second;
    my $made = with_keyed_stripe(
        sub { $payment->schedule_remaining_instalments($db) },
        schedule_made => sub {
            $db2->query(q{SET lock_timeout = '200ms'});
            eval { $other->schedule_remaining_instalments($db2); 1 } or $second = $@;
            $db2->query('RESET lock_timeout');
        },
    );
    like $second, qr/lock timeout/, 'the second job waited on the first';
    is scalar @$made, 1, 'one schedule while both ran';

    # Once the first has committed, the second -- still holding the row it
    # loaded before -- finds the schedule rather than making another.
    my $again = with_keyed_stripe( sub { $other->schedule_remaining_instalments($db2) } );
    is_deeply $again, [], 'the second job makes no schedule afterwards';
    is $other->stripe_schedule_id, $made->[0][1], 'and reports the first one';
    is scheduled_rows($payment), 2, 'and adds no rows';
};

subtest 'schedule uses the account instalment one was charged on' => sub {
    my $payment = first_instalment();
    $db->query( q{UPDATE registry.tenants SET stripe_connect_account_id = 'acct_moved'
                   WHERE slug = ?}, $seller );

    my $calls = with_stripe_calls( sub { $payment->schedule_remaining_instalments($db) } );
    Test::Registry::Fixtures::platform_seller($db);

    is scalar @$calls, 3, 'the intent, the product and the schedule';
    is_deeply [ map { $_->[1] } @$calls ], [ ('acct_platform_test') x 3 ],
        'all on the account the customer was charged on, not the new one';

    # A later refund of instalment two goes through that row's own client, so
    # the row must carry the account too or it dies with no account to refund on.
    my $later = $db->query( q{
        SELECT metadata->>'stripe_account_id' FROM payments
         WHERE metadata->>'instalment_of' = ? ORDER BY instalment_seq
    }, $payment->id )->arrays->flatten->to_array;
    is_deeply $later, [ ('acct_platform_test') x 2 ],
        'and the later instalment rows carry that same account';
};

# A later instalment's fee is recorded when its invoice is paid, months on, and
# must name the plan that priced the schedule -- not whatever the tenant is on.
subtest 'later instalment rows carry the plan snapshotted on instalment one' => sub {
    my $payment = first_instalment();
    is $payment->metadata->{platform_pricing_plan_id}, $plan_id,
        'instalment one snapshotted the plan';

    with_stripe_calls( sub { $payment->schedule_remaining_instalments($db) } );

    my $later = $db->query( q{
        SELECT metadata->>'platform_pricing_plan_id' FROM payments
         WHERE metadata->>'instalment_of' = ? ORDER BY instalment_seq
    }, $payment->id )->arrays->flatten->to_array;
    is_deeply $later, [ ($plan_id) x 2 ], 'and so does each later row';
};

# The product and schedule creates carry Idempotency-Keys, so a retry after a
# crash must send what the first run sent; a rate read afresh would differ
# after a plan change and Stripe would answer with an idempotency error.
subtest 'the instalment schedule uses the rate snapshotted on instalment one' => sub {
    my $payment = first_instalment();
    $db->query( q{UPDATE registry.tenants SET platform_pricing_plan_id =
                    (SELECT id FROM registry.pricing_plans WHERE plan_name = 'Registry Free' LIMIT 1)
                   WHERE slug = ?}, $seller );
    is Registry::PriceOps::RevenueShare::revenue_share_fraction_for_tenant( $db, $seller ), 0,
        'the seller has since moved to a plan with no revenue share';

    my $calls = with_stripe_calls( sub { $payment->schedule_remaining_instalments($db) } );
    $db->query( 'UPDATE registry.tenants SET platform_pricing_plan_id = ? WHERE slug = ?',
        $plan_id, $seller );

    is $calls->[2][2]{'default_settings[application_fee_percent]'}, $plan_pct,
        'the schedule still takes the rate instalment one was quoted at';
};
