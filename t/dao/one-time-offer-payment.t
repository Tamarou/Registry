# ABOUTME: A one-time payment for an amount a prior step owes under a stamped offer version: stamped, direct, refused when unsafe.
# ABOUTME: Settled by payment_intent.succeeded on the Connect endpoint, which continues the run with nobody present.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::PricingProbe qw( give_tenant_terms );
use Test::Registry::Offers qw( offer_terms );
use Test::Registry::StripeWebhook;

use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::DAO::Payment;
use Registry::DAO::Offer;
use Registry::DAO::Resource;
use Registry::PriceOps::PlatformTerms qw( platform_terms_for_tenant );

local $ENV{STRIPE_WEBHOOK_SECRET}         = 'whsec_local_one_time_offer';
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_local_one_time_offer_connect';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub ( $c, $tenant = undef ) {
    defined $tenant ? Registry::DAO->new( url => $test_db->uri, schema => $tenant ) : $dao } );

# A seller: a tenant schema with a Stripe account, the platform terms it is
# charged under, a published offer version of its own, a buyer, and a
# workflow whose middle step takes the one-time payment.
my $sellers = 0;
sub seller (%opt) {
    my $n     = ++$sellers;
    my $slug  = "otp_${n}_$$";
    my $admin = Registry::DAO::User->create( $db, {
        username => "otp_admin_${n}_$$", email => "otp_admin_${n}_$$\@test.example",
        name => "OTP Admin $n", user_type => 'admin' } );
    my $account = $opt{no_account} ? undef : "acct_otp_${n}_$$";
    Registry::DAO::Tenant->provision( $db, {
        name => "OTP $n $$", slug => $slug, users => [$admin],
        ( $account ? ( stripe_connect_account_id => $account,
                       stripe_charges_enabled => 1, stripe_details_submitted => 1 ) : () ) } );
    give_tenant_terms( $db, $slug, { rate => $opt{rate} // '0.025' } ) unless $opt{no_terms};

    my $tdb      = Registry::DAO->new( url => $test_db->uri, schema => $slug )->db;
    my $resource = Registry::DAO::Resource->create( $tdb, { name => 'Studio seat', kind => 'unbounded' } );
    my $version  = Registry::DAO::Offer->create( $tdb, { name => 'Drop-in' } )
        ->draft( $tdb, offer_terms( $resource->id ) )->publish($tdb);
    my $buyer = Registry::DAO::User->create( $tdb, {
        username => "otp_buyer_${n}_$$", email => "otp_buyer_${n}_$$\@test.example",
        name => "OTP Buyer $n", user_type => 'parent' } );

    my $wf = Registry::DAO::Workflow->create( $tdb, {
        name => "OTP $n", slug => "otp-$n-$$", description => 'one-time payment test' } );
    $wf->add_step( $tdb, { slug => $_->[0], class => $_->[1] } ) for
        [ before => 'Registry::DAO::WorkflowStep' ],
        [ pay    => 'Registry::DAO::WorkflowSteps::OneTimePayment' ],
        [ after  => 'Registry::DAO::WorkflowStep' ];

    return { slug => $slug, account => $account, db => $tdb, version => $version,
             buyer => $buyer, workflow => $wf };
}

# A run parked after `before`, owing what a prior step wrote under the
# server-owned owed_payment key: by default 1060 cents under $s's version.
sub owed_run ( $s, %owed ) {
    my $run = $s->{workflow}->new_run( $s->{db}, {} );
    $run->process( $s->{db}, $s->{workflow}->first_step( $s->{db} ), {} );
    $run->update_data( $s->{db}, {
        user_id       => $s->{buyer}->id,
        __tenant_slug => $s->{slug},
        owed_payment  => {
            offer_version_id => $s->{version}->id,
            payment_plan     => 'pay',
            amount_cents     => 1060,
            description      => 'Change fee',
            purpose          => 'change_fee',
            %owed,
        },
    } );
    return $run;
}

sub pay_step ($s) { $s->{workflow}->get_step( $s->{db}, { slug => 'pay' } ) }

sub payments_of ( $s, $run ) {
    return $s->{db}->query( q{SELECT * FROM payments WHERE metadata->>'workflow_run_id' = ?},
        $run->id )->expand->hashes->to_array;
}

my $studio = seller();

subtest 'one time payment stamped and built as direct charge' => sub {
    my $run = owed_run($studio);
    my $out = pay_step($studio)->owed_payment( $studio->{db}, $run );
    my $payment = $out->{payment} or return fail 'no payment: ' . explain $out;

    my $rows = payments_of( $studio, $run );
    is scalar @$rows, 1, 'one payment row';
    is $rows->[0]{status}, 'pending', 'pending';
    is $rows->[0]{amount_cents}, 1060, 'for the amount owed';
    is $rows->[0]{offer_version_id}, $studio->{version}->id, 'stamped with the offer version sold under';

    my $terms = platform_terms_for_tenant( $db, $studio->{slug} );
    is $payment->metadata->{platform_offer_version_id}, $terms->{id},
        "stamped with the seller's platform offer version";
    is $payment->metadata->{platform_payment_plan_id}, $terms->{plan_id}, 'and its plan';
    is Registry::DAO::WorkflowRun->find( $studio->{db}, { id => $run->id } )->data->{owed_payment_id},
        $payment->id, 'the run names its payment';

    my $params = $payment->_intent_params( $studio->{db}, { description => 'Change fee' } );
    is $payment->stripe_client->stripe_account, $studio->{account},
        "the intent is created on the seller's own account";
    is $params->{amount}, 1060, 'charging the amount owed';
    is $params->{application_fee_amount}, 26,
        'with the 2.5% revenue share, 26.5 rounded half to even';
    ok !grep( { /\Atransfer_data/ } keys %$params ), 'and no transfer_data';
    ok !exists $params->{on_behalf_of}, 'nor on_behalf_of';
    like $params->{_idempotency_key}, qr/\Api-create:/, 'under the payment\'s idempotency key';
};

my $minion = $t->app->minion;

# The continue_workflow_run jobs queued for $run.
sub continuations ($run) {
    my $jobs = $minion->jobs( { tasks => ['continue_workflow_run'] } );
    my @mine;
    while ( my $job = $jobs->next ) {
        push @mine, $job if ( $job->{args}[0]{run_id} // '' ) eq $run->id;
    }
    return @mine;
}

# A payment started for $run, with the intent Stripe answered recorded on it.
sub started_payment ( $s, $run, $intent_id ) {
    my $payment = pay_step($s)->owed_payment( $s->{db}, $run )->{payment};
    $payment->_record_intent( $s->{db}, { id => $intent_id, client_secret => "${intent_id}_secret" } );
    return $payment;
}

# Sign and post a Connect event for $intent_id on $account.
sub connect_event ( $type, $account, $intent_id, $payment_id, %opt ) {
    my $event = {
        ( $opt{id} ? ( id => $opt{id} ) : () ),
        type    => $type,
        account => $account,
        data    => { object => {
            id                     => $intent_id,
            amount                 => 1060,
            application_fee_amount => 26,
            metadata               => { payment_id => $payment_id },
        } },
    };
    return Test::Registry::StripeWebhook::post_connect( $t, $event );
}

sub status_of ( $s, $payment ) {
    Registry::DAO::Payment->find( $s->{db}, { id => $payment->id } )->status;
}

sub step_of ( $s, $run ) {
    Registry::DAO::WorkflowRun->find( $s->{db}, { id => $run->id } )->latest_step( $s->{db} )->slug;
}

subtest 'succeeded payment continues run unattended' => sub {
    my $run     = owed_run($studio);
    my $payment = started_payment( $studio, $run, "pi_otp_ok_$$" );

    connect_event( 'payment_intent.succeeded', $studio->{account}, "pi_otp_ok_$$",
        $payment->id, id => "evt_otp_ok_$$" )->status_is(200);

    my $paid = Registry::DAO::Payment->find( $studio->{db}, { id => $payment->id } );
    is $paid->status, 'completed', 'the payment is completed';
    is $paid->platform_fee_cents, 26, 'with the fee Stripe reported';
    is $paid->platform_offer_version_id,
        platform_terms_for_tenant( $db, $studio->{slug} )->{id},
        'stamped with the platform offer version it was taken under';

    my @queued = continuations($run);
    is scalar @queued, 1, 'one continue_workflow_run is queued for the run';
    is_deeply $queued[0]{args}, [ { tenant => $studio->{slug}, run_id => $run->id } ],
        "naming the run and the seller's schema";

    connect_event( 'payment_intent.succeeded', $studio->{account}, "pi_otp_ok_$$",
        $payment->id, id => "evt_otp_ok_$$" )->status_is(200);
    connect_event( 'payment_intent.succeeded', $studio->{account}, "pi_otp_ok_$$",
        $payment->id, id => "evt_otp_ok_again_$$" )->status_is(200);
    is scalar continuations($run), 1, 'posting it again, or redelivered, queues no second';

    $minion->perform_jobs( { id => $queued[0]{id} } );
    my $info = $minion->job( $queued[0]{id} )->info;
    is $info->{state}, 'finished', 'the job finished' or diag explain $info->{result};
    is_deeply $info->{result}, { run_id => $run->id, stopped_at => 'after', reason => 'completed' },
        'the run went on past the payment with nobody present';
    is step_of( $studio, $run ), 'after', 'and is complete';
};

done_testing;
