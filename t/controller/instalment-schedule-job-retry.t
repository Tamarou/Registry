# ABOUTME: The instalment_schedule job as the Connect webhook enqueues it, run by Minion's own worker.
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
use Test::Registry::StripeWebhook;
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Payment;
use Registry::Service::Stripe;

local $ENV{STRIPE_SECRET_KEY}             = 'sk_test_schedule_retry';
local $ENV{STRIPE_WEBHOOK_SECRET}         = 'whsec_test_schedule_retry';
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_test_schedule_retry_connect';

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

my $parent = Registry::DAO::User->create( $tdb, {
    username => "sr_parent_$$", email => "sr_parent_$$\@test.example",
    name => 'SR Parent', user_type => 'parent' } );

# The real dao helper, not an override: the job finds the tenant's schema by slug.
my $t      = Test::Registry::Mojo->new('Registry');
my $minion = $t->app->minion;

my @logs;
$t->app->log->unsubscribe('message');
$t->app->log->level('info');
$t->app->log->on( message => sub ( $log, $level, @lines ) { push @logs, [ $level, "@lines" ] } );

my $sales = 0;

# Instalment one of three, settled by its success event: the webhook enqueues
# the job. Returns the payment and the job it queued.
sub a_settled_first_instalment () {
    my $sale = Registry::DAO::Payment->create( $tdb, {
        user_id => $parent->id, amount_cents => 3333, status => 'pending',
        instalment_seq => 1, instalment_count => 3,
        metadata => {
            enrollment_items => [],
            tenant_slug      => $slug,
            instalment_plan  => [
                { amount_cents => 3333, due_date => '2026-06-01' },
                { amount_cents => 3333, due_date => '2026-07-01' },
                { amount_cents => 3334, due_date => '2026-08-01' },
            ],
        } } );
    $tdb->update( 'payments', { stripe_payment_intent_id => 'pi_sr_' . $sale->id },
        { id => $sale->id } );

    Test::Registry::StripeWebhook::post_connect( $t, {
        id      => "evt_sr_${$}_" . ++$sales,
        type    => 'payment_intent.succeeded',
        account => $account,
        data    => { object => {
            id => 'pi_sr_' . $sale->id, amount => 3333,
            metadata => { payment_id => $sale->id },
        } },
    } )->status_is(200);

    my $job = $minion->jobs( { tasks => ['instalment_schedule'], notes => [ $sale->id ] } )
        ->next;
    return ( $sale, $job );
}

subtest 'the schedule job is enqueued to be retried' => sub {
    my ( $sale, $job ) = a_settled_first_instalment();
    ok $job, 'the settlement queued the schedule job';
    cmp_ok $job->{attempts}, '>', 1, 'with more than the one attempt Minion defaults to';
    is $job->{attempts}, 10, 'ten, as the webhook names';
    $minion->job( $job->{id} )->remove;
};

subtest 'a job that fails once and succeeds on retry makes one schedule' => sub {
    my ( $sale, $job ) = a_settled_first_instalment();

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

    # Retry at once rather than after Minion's backoff, so one worker pass sees both runs.
    my $backoff = $minion->backoff;
    $minion->backoff( sub ($retries) { 0 } );
    $minion->perform_jobs_in_foreground( { id => $job->{id} } );
    $minion->backoff($backoff);

    my $info = $minion->job( $job->{id} )->info;
    is $info->{state},   'finished', 'the job finished';
    is $info->{retries}, 1,          'on its second run';
    is $tries, 2, 'Stripe was asked twice';
    is_deeply \@made, ['sub_sched_sr_2'], 'and made one schedule';

    my $row = Registry::DAO::Payment->find( $tdb, { id => $sale->id } );
    is $row->stripe_schedule_id, 'sub_sched_sr_2', 'which is the one recorded';
    is $tdb->query( q{SELECT count(*) FROM payments WHERE metadata->>'instalment_of' = ?},
        $sale->id )->array->[0], 2, 'with one row per remaining instalment';
};

# Every Stripe call the job makes for $sale stubbed: the schedule create
# always answers $error, as Stripe replays a stored 500 under one
# Idempotency-Key for 24 hours; listing the customer's schedules returns
# @$listed once a create has run, as Stripe may have made the schedule it
# answered 500 for. Runs $job to its end and returns what Stripe was asked.
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

    my $backoff = $minion->backoff;
    $minion->backoff( sub ($retries) { 0 } );
    $minion->perform_jobs_in_foreground( { id => $job->{id} } );
    $minion->backoff($backoff);
    return { keys => \@keys, lists => \@lists, info => $minion->job( $job->{id} )->info };
}

sub alerts_for ($sale) {
    $tdb->query( q{SELECT subject, message FROM notifications
                    WHERE user_id = ? AND message LIKE ?}, $admin->id, '%' . $sale->id . '%' )
        ->hashes->to_array;
}

subtest 'a replayed 500 under the key: a retry finds the schedule Stripe made and records it' => sub {
    my ( $sale, $job ) = a_settled_first_instalment();
    my $ran = run_against_replayed_500( $job, 'Stripe api_error: An unknown error occurred',
        [ { id => 'sub_sched_other', status => 'active', metadata => { payment_id => 'someone-else' } },
          { id => 'sub_sched_made',  status => 'not_started', metadata => { payment_id => $sale->id },
            # Our fee in the two phases we send, so it is ours to adopt.
            default_settings => { application_fee_percent => 100
                * Registry::PriceOps::RevenueShare::revenue_share_fraction_for_tenant( $db, $slug ) },
            phases => [ {}, {} ] } ] );

    is $ran->{info}{state}, 'finished', 'the job finishes';
    is scalar @{ $ran->{keys} }, 1, 'after one create, answered 500';
    is scalar @{ $ran->{lists} }, 2, 'each run first listed schedules';
    is $ran->{lists}[1]{customer}, 'cus_sr', "the payment's customer's";
    my $row = Registry::DAO::Payment->find( $tdb, { id => $sale->id } );
    is $row->stripe_schedule_id, 'sub_sched_made', 'and records the one made for this payment';
    is $tdb->query( q{SELECT count(*) FROM payments WHERE metadata->>'instalment_of' = ?},
        $sale->id )->array->[0], 2, 'with one row per remaining instalment';
    is scalar @{ alerts_for($sale) }, 0, 'and nobody is alerted';
};

subtest 'a job whose last attempt fails alerts an operator naming payment and tenant' => sub {
    my ( $sale, $job ) = a_settled_first_instalment();
    @logs = ();
    my $ran = run_against_replayed_500( $job, 'Stripe api_error: An unknown error occurred', [] );

    is $ran->{info}{state}, 'failed', 'the job ends failed';
    is scalar @{ $ran->{keys} }, 10, 'after ten attempts';
    is_deeply [ sort keys %{ { map { $_ => 1 } @{ $ran->{keys} } } } ],
        [ 'instalment_schedule:' . $sale->id . ':schedule' ],
        'every one under the same key: never a new key';
    is scalar @{ $ran->{lists} }, 10, 'each attempt first looked for a schedule Stripe made';
    ok !Registry::DAO::Payment->find( $tdb, { id => $sale->id } )->stripe_schedule_id,
        'nothing is recorded';

    my $alerts = alerts_for($sale);
    is scalar @$alerts, 1, "the tenant's admin is alerted once, at the last attempt";
    like $alerts->[0]{message}, qr/\Q$slug\E/, 'naming the tenant';
    my @errors = grep { $_->[0] eq 'error' && $_->[1] =~ /\Q${\ $sale->id }\E/ } @logs;
    is scalar @errors, 1, 'and the platform log says so once at error';
    like $errors[0][1] // '', qr/\Q$slug\E/, 'naming the tenant';
};

done_testing;
