# ABOUTME: The instalment_schedule job as the Connect webhook enqueues it, run by Minion's own worker.
# ABOUTME: A failed run is retried, and a retry after a failure still makes one Stripe schedule.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use experimental qw(signatures);
use Test::More;
use Test::Registry::DB;
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

my $parent = Registry::DAO::User->create( $tdb, {
    username => "sr_parent_$$", email => "sr_parent_$$\@test.example",
    name => 'SR Parent', user_type => 'parent' } );

# The real dao helper, not an override: the job finds the tenant's schema by slug.
my $t      = Test::Registry::Mojo->new('Registry');
my $minion = $t->app->minion;

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

    # Stripe answers the first schedule create with an error, then makes it.
    my ( $tries, @made ) = (0);
    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent = sub ( $s, $pi ) {
        return { id => $pi, customer => 'cus_sr', payment_method => 'pm_sr' };
    };
    local *Registry::Service::Stripe::create_product = sub ( $s, $p ) {
        return { id => 'prod_sr' };
    };
    local *Registry::Service::Stripe::create_subscription_schedule = sub ( $s, $p ) {
        die "Stripe API error: 500 Internal Server Error\n" unless $tries++;
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

done_testing;
