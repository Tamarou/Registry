# ABOUTME: The instalment_schedule and cancel_instalment_schedule jobs for one child's entitlement, run by Minion's own worker.
# ABOUTME: Retries make one schedule, adopt one a replayed 500 hid, and alert when the last attempt fails.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use experimental qw(signatures);
use Test::More;
use Test::Registry::DB;
use Test::Registry::PricingProbe qw( state_platform_terms );
use Test::Registry::Mojo;
use Test::Registry::InstalmentCheckout qw( instalment_checkout );
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Payment;
use Registry::Job::InstalmentSchedule;
use Registry::Service::Stripe;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_schedule_retry';

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;

my $slug    = "sr_tenant_$$";
my $account = "acct_sr_$$";
my $admin   = Registry::DAO::User->create( $db, {
    username => "sr_admin_$$", email => "sr_admin_$$\@test.example",
    name => 'SR Admin', user_type => 'admin' } );
Registry::DAO::Tenant->provision( $db, {
    name => "SR Tenant $$", slug => $slug, users => [$admin],
    stripe_connect_account_id => $account,
    stripe_charges_enabled => 1, stripe_details_submitted => 1 } );
my $tdb = Registry::DAO->new( url => $test_db->uri, schema => $slug )->db;
state_platform_terms( $db, $slug, { rate => 0 } );

# The real dao helper, not an override: the job finds the tenant's schema by slug.
my $t      = Test::Registry::Mojo->new('Registry');
my $minion = $t->app->minion;

my @logs;
$t->app->log->unsubscribe('message');
$t->app->log->level('info');
$t->app->log->on( message => sub ( $log, $level, @lines ) { push @logs, [ $level, "@lines" ] } );

# A child's paid checkout in three parts, and the $task job for its
# entitlement, queued as checkout queues it.
sub queued ( $task, $c = instalment_checkout( $tdb, slug => $slug ) ) {
    Registry::Job::InstalmentSchedule->enqueue( $minion, $task, $c->{entitlement}->id, $slug );
    my $job = $minion->jobs( { tasks => [$task], notes => [ $c->{entitlement}->id ] } )->next;
    return ( $c, $job );
}

sub run ($job) {
    my $backoff = $minion->backoff;
    $minion->backoff( sub ($retries) { 0 } );
    $minion->perform_jobs_in_foreground( { id => $job->{id} } );
    $minion->backoff($backoff);
    return $minion->job( $job->{id} )->info;
}

sub scheduled ($c) {
    return $tdb->select( 'payments', [qw( stripe_schedule_id )],
        { entitlement_id => $c->{entitlement}->id } )->arrays->flatten->to_array;
}

subtest 'the jobs are queued to be retried, once per entitlement' => sub {
    for my $task (qw( instalment_schedule cancel_instalment_schedule )) {
        my ( $c, $job ) = queued($task);
        is_deeply $job->{args}, [ $c->{entitlement}->id, $slug ], "$task names the entitlement and tenant";
        is $job->{attempts}, 10, 'with ten attempts';
        Registry::Job::InstalmentSchedule->enqueue( $minion, $task, $c->{entitlement}->id, $slug );
        is $minion->jobs( { tasks => [$task], notes => [ $c->{entitlement}->id ] } )->total, 1,
            'and a second ask while it waits adds none';
        $minion->job( $job->{id} )->remove;
    }
};

subtest 'a job that fails once and succeeds on retry makes one schedule' => sub {
    my ( $c, $job ) = queued('instalment_schedule');

    # The first schedule create never reaches Stripe, then makes it. Not a 500:
    # Stripe would replay a 500 under the same key (see below).
    my ( $tries, @made ) = (0);
    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent = sub ( $s, $pi ) {
        return { id => $pi, customer => 'cus_sr', payment_method => 'pm_sr' };
    };
    local *Registry::Service::Stripe::create_product = sub ( $s, $p ) {
        return { id => 'prod_sr' };
    };
    local *Registry::Service::Stripe::list_subscription_schedules = sub ( $s, $p ) {
        return { data => [] };
    };
    local *Registry::Service::Stripe::create_subscription_schedule = sub ( $s, $p ) {
        die "Connect timeout\n" unless $tries++;
        push @made, "sub_sched_sr_$tries";
        return { id => $made[-1] };
    };

    my $info = run($job);
    is $info->{state},   'finished', 'the job finished';
    is $info->{retries}, 1,          'on its second run';
    is $tries, 2, 'Stripe was asked twice';
    is_deeply \@made, ['sub_sched_sr_2'], 'and made one schedule';
    is_deeply scheduled($c), [ ('sub_sched_sr_2') x 2 ],
        'which is the one recorded, on one row per remaining instalment';
};

# Every Stripe call the job makes stubbed: the schedule create always answers
# $error, as Stripe replays a stored 500 under one Idempotency-Key for 24
# hours; listing the customer's schedules returns @$listed once a create has
# run, as Stripe may have made the schedule it answered 500 for. Runs $job to
# its end and returns what Stripe was asked.
sub run_against_replayed_500 ( $job, $error, $listed ) {
    my ( @keys, @lists );
    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent = sub ( $s, $pi ) {
        return { id => $pi, customer => 'cus_sr', payment_method => 'pm_sr' };
    };
    local *Registry::Service::Stripe::create_product = sub ( $s, $p ) {
        return { id => 'prod_sr' };
    };
    local *Registry::Service::Stripe::create_subscription_schedule = sub ( $s, $p ) {
        push @keys, $p->{_idempotency_key};
        die "$error\n";
    };
    local *Registry::Service::Stripe::list_subscription_schedules = sub ( $s, $p ) {
        push @lists, $p;
        return { data => @keys ? $listed : [] };
    };
    return { keys => \@keys, lists => \@lists, info => run($job) };
}

sub alerts_for ($c) {
    $tdb->query( q{SELECT subject, message FROM notifications
                    WHERE user_id = ? AND message LIKE ?}, $admin->id, '%' . $c->{entitlement}->id . '%' )
        ->hashes->to_array;
}

subtest 'a replayed 500 under the key: a retry finds the schedule Stripe made and records it' => sub {
    my ( $c, $job ) = queued('instalment_schedule');
    my $eid = $c->{entitlement}->id;
    my $ran = run_against_replayed_500( $job, 'Stripe api_error: An unknown error occurred',
        [ { id => 'sub_sched_other', status => 'active', metadata => { entitlement_id => 'someone-else' } },
          { id => 'sub_sched_made',  status => 'not_started', metadata => { entitlement_id => $eid },
            # Our fee in the three phases we send ($0, then 3333, 3334), so it is ours to adopt.
            default_settings => { application_fee_percent => 100
                * Registry::PriceOps::RevenueShare::revenue_share_fraction_for_tenant( $db, $slug ) },
            phases => [ {}, {}, {} ] } ] );

    is $ran->{info}{state}, 'finished', 'the job finishes';
    is scalar @{ $ran->{keys} }, 1, 'after one create, answered 500';
    is scalar @{ $ran->{lists} }, 2, 'each run first listed schedules';
    is $ran->{lists}[1]{customer}, 'cus_sr', "the checkout charge's customer's";
    is_deeply scheduled($c), [ ('sub_sched_made') x 2 ],
        'and records the one made for this entitlement, one row per remaining instalment';
    is scalar @{ alerts_for($c) }, 0, 'and nobody is alerted';
};

subtest 'a cancel that fails once is retried until Stripe cancels' => sub {
    my ( $c, $job ) = queued('cancel_instalment_schedule');
    $tdb->insert( 'payments', { user_id => $c->{parent}, amount_cents => 3333, status => 'pending',
        instalment_seq => 2, instalment_count => 3, stripe_schedule_id => 'sub_sched_to_cancel',
        entitlement_id => $c->{entitlement}->id } );

    my ( $tries, @cancelled ) = (0);
    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_subscription_schedule = sub ( $s, $id ) {
        return { id => $id, status => @cancelled ? 'canceled' : 'active' };
    };
    local *Registry::Service::Stripe::cancel_subscription_schedule = sub ( $s, $id, $p = {} ) {
        die "Connect timeout\n" unless $tries++;
        push @cancelled, [ $s->stripe_account, $id ];
        return { id => $id, status => 'canceled' };
    };

    my $info = run($job);
    is $info->{state}, 'finished', 'the job finished';
    is $info->{retries}, 1, 'on its second run';
    is_deeply \@cancelled, [ [ $account, 'sub_sched_to_cancel' ] ],
        "the child's schedule is cancelled once, on the studio's account";
};

subtest 'the last failed attempt alerts admins' => sub {
    my ( $c, $job ) = queued('instalment_schedule');
    @logs = ();
    my $ran = run_against_replayed_500( $job, 'Stripe api_error: An unknown error occurred', [] );

    is $ran->{info}{state}, 'failed', 'the job ends failed';
    is scalar @{ $ran->{keys} }, 10, 'after ten attempts';
    is_deeply [ sort keys %{ { map { $_ => 1 } @{ $ran->{keys} } } } ],
        [ 'instalment_schedule:' . $c->{entitlement}->id . ':schedule' ],
        'every one under the same key: never a new key';
    is scalar @{ $ran->{lists} }, 10, 'each attempt first looked for a schedule Stripe made';
    is_deeply scheduled($c), [], 'nothing is recorded';

    my $alerts = alerts_for($c);
    is scalar @$alerts, 1, "the tenant's admin is alerted once, at the last attempt";
    like $alerts->[0]{message}, qr/\Q$slug\E/, 'naming the tenant';
    my @errors = grep { $_->[0] eq 'error' && $_->[1] =~ /\Q${\ $c->{entitlement}->id }\E/ } @logs;
    is scalar @errors, 1, 'and the platform log says so once at error';
    like $errors[0][1] // '', qr/\Q$slug\E/, 'naming the tenant';
};

subtest 'the last failed cancel attempt alerts admins' => sub {
    my ( $c, $job ) = queued('cancel_instalment_schedule');
    $tdb->insert( 'payments', { user_id => $c->{parent}, amount_cents => 3333, status => 'pending',
        instalment_seq => 2, instalment_count => 3, stripe_schedule_id => 'sub_sched_stuck',
        entitlement_id => $c->{entitlement}->id } );
    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_subscription_schedule = sub ( $s, $id ) {
        return { id => $id, status => 'active' };
    };
    local *Registry::Service::Stripe::cancel_subscription_schedule = sub ( $s, $id, $p = {} ) {
        die "Stripe api_error: An unknown error occurred\n";
    };

    is run($job)->{state}, 'failed', 'the job ends failed';
    my $alerts = alerts_for($c);
    is scalar @$alerts, 1, "the tenant's admin is alerted once";
    like $alerts->[0]{subject}, qr/could not be cancelled/, 'that the instalments were not cancelled';
};

done_testing;
