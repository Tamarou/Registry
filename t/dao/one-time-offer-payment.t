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

use Mojo::Promise;
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
# A priced payment is refused outright without a key; no Stripe call is made here.
local $ENV{STRIPE_SECRET_KEY} = 'sk_test_placeholder';

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
            metadata               => { payment_id => $payment_id,
                                        ( $opt{tenant_slug} ? ( tenant_slug => $opt{tenant_slug} ) : () ) },
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
    is $queued[0]{attempts}, 3, 'with three attempts, so a passing failure is retried before the run halts';

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

# Processing the step for $run: refused synchronously, before any promise (so
# before any call to Stripe), with no payment row for the run.
sub refused_without_charge ( $s, $run, $form, $why ) {
    my $result = pay_step($s)->process( $s->{db}, $form, $run );
    ok !( $result isa Mojo::Promise ), "$why: refused before Stripe is called";
    ok $result->{errors} && @{ $result->{errors} }, "$why: with an error" or diag explain $result;
    is scalar @{ payments_of( $s, $run ) }, 0, "$why: and no payment row";
}

# A run on the platform tenant parked on a passthrough step, for posting a
# form through the controller to the next one.
my $form_wf = Registry::DAO::Workflow->create( $db, {
    name => 'OTP Form', slug => "otp-form-$$", description => 'posted keys', public => 1 } );
$form_wf->add_step( $db, { slug => $_, class => 'Registry::DAO::WorkflowStep' } )
    for qw( landing next complete );

subtest 'form submitted amount ignored' => sub {
    # Posted through the controller, none of it reaches the run's data.
    my $run = $form_wf->new_run( $db, {} );
    $run->process( $db, $form_wf->first_step($db), {} );
    $t->post_ok( "/otp-form-$$/${\ $run->id }/next" => form => {
        'owed_payment[amount_cents]'     => 1,
        'owed_payment[offer_version_id]' => $studio->{version}->id,
        'owed_payment[payment_plan]'     => 'pay',
        owed_payment_id                  => '00000000-0000-0000-0000-000000000001',
    } )->status_is(302);
    my $stored = Registry::DAO::WorkflowRun->find( $db, { id => $run->id } )->data;
    ok !exists $stored->{owed_payment}, 'a posted owed_payment is not stored';
    ok !exists $stored->{owed_payment_id}, 'nor a posted owed_payment_id';

    # Handed to the step directly, the form is not read for what is owed.
    my $owes_nothing = owed_run( $studio, amount_cents => 0 );
    refused_without_charge( $studio, $owes_nothing, {
        amount_cents => 1060, offer_version_id => $studio->{version}->id, payment_plan => 'pay',
        owed_payment => { amount_cents => 1060, offer_version_id => $studio->{version}->id,
                          payment_plan => 'pay' },
    }, 'a run owing nothing with a valid amount on the form' );

    my $run_owing = owed_run($studio);
    my $payment   = pay_step($studio)->owed_payment( $studio->{db}, $run_owing )->{payment};
    is $payment->amount_cents, 1060, 'what is charged is what the run owes';
};

subtest 'missing owed amount refused' => sub {
    my $run = owed_run($studio);
    $run->update_data( $studio->{db}, { owed_payment => undef } );
    refused_without_charge( $studio, $run, {}, 'nothing owed' );

    for my $missing (qw( amount_cents offer_version_id payment_plan )) {
        refused_without_charge( $studio, owed_run( $studio, $missing => undef ), {},
            "no $missing" );
    }
};

subtest 'invalid amount refused' => sub {
    for my $amount ( -1060, 0, '10.60', 10.6, '1e3', ' 1060', '1060abc', 1_000_000_000, [1060] ) {
        refused_without_charge( $studio, owed_run( $studio, amount_cents => $amount ), {},
            'amount ' . ( ref $amount ? 'a list' : "'$amount'" ) );
    }
};

subtest 'seller without platform entitlement refused' => sub {
    my $unpriced = seller( no_terms => 1 );
    my @warned;
    local $SIG{__WARN__} = sub { push @warned, @_ };
    refused_without_charge( $unpriced, owed_run($unpriced), {}, 'no platform entitlement' );
    like "@warned", qr/'\Q$unpriced->{slug}\E' holds no platform entitlement/,
        'and the operator is told which tenant';
};

subtest 'seller without stripe account refused' => sub {
    my $unconnected = seller( no_account => 1 );
    my @warned;
    local $SIG{__WARN__} = sub { push @warned, @_ };
    refused_without_charge( $unconnected, owed_run($unconnected), {}, 'no Stripe account' );
    like "@warned", qr/'\Q$unconnected->{slug}\E' is not Stripe Connect ready/,
        'and the operator is told which tenant';
};

subtest 'zero fee omits application fee' => sub {
    # 2.5% of 19 cents is 0.475, which rounds to no fee at all.
    my $run     = owed_run( $studio, amount_cents => 19 );
    my $payment = pay_step($studio)->owed_payment( $studio->{db}, $run )->{payment};
    my $params  = $payment->_intent_params( $studio->{db}, {} );
    is $params->{amount}, 19, 'the charge is still made';
    ok !exists $params->{application_fee_amount}, 'with no application_fee_amount, not 0';
};

subtest 'double processing creates one payment' => sub {
    my $run    = owed_run($studio);
    my $first  = pay_step($studio)->owed_payment( $studio->{db}, $run )->{payment};
    $run = Registry::DAO::WorkflowRun->find( $studio->{db}, { id => $run->id } );
    my $second = pay_step($studio)->owed_payment( $studio->{db}, $run )->{payment};

    is $second->id, $first->id, 'the second pass reuses the payment';
    is scalar @{ payments_of( $studio, $run ) }, 1, 'one payment row';
    is $second->_intent_params( $studio->{db}, {} )->{_idempotency_key},
        $first->_intent_params( $studio->{db}, {} )->{_idempotency_key},
        'under one idempotency key, so Stripe makes one PaymentIntent';

    $run->update_data( $studio->{db}, { owed_payment => {
        %{ $run->data->{owed_payment} }, amount_cents => 2000 } } );
    my $changed = pay_step($studio)->owed_payment( $studio->{db}, $run );
    ok $changed->{errors}, 'a changed amount is refused rather than re-priced under the key';
    is scalar @{ payments_of( $studio, $run ) }, 1, 'and no second row is made';
};

subtest 'unknown payment intent ignored' => sub {
    my $run     = owed_run($studio);
    my $payment = started_payment( $studio, $run, "pi_otp_ours_$$" );

    connect_event( 'payment_intent.succeeded', $studio->{account}, "pi_otp_not_ours_$$",
        $payment->id )->status_is(200);
    connect_event( 'payment_intent.succeeded', $studio->{account}, "pi_otp_nowhere_$$",
        '00000000-0000-4000-8000-000000000000' )->status_is(200);

    is status_of( $studio, $payment ), 'pending', 'the payment is unchanged';
    is scalar continuations($run), 0, 'and no job is queued';
};

subtest 'cross account event does not complete payment' => sub {
    my $other   = seller();
    my $run     = owed_run($studio);
    my $payment = started_payment( $studio, $run, "pi_otp_cross_$$" );

    # Tenant A's own slug in the metadata, which tenant B's account writes.
    connect_event( 'payment_intent.succeeded', $other->{account}, "pi_otp_cross_$$",
        $payment->id, tenant_slug => $studio->{slug} )->status_is(200);

    is status_of( $studio, $payment ), 'pending', "tenant A's payment is not completed";
    is scalar continuations($run), 0, 'and its run is not continued';
};

subtest 'payment failed does not hand on run' => sub {
    my $run     = owed_run($studio);
    my $payment = started_payment( $studio, $run, "pi_otp_failed_$$" );

    connect_event( 'payment_intent.payment_failed', $studio->{account}, "pi_otp_failed_$$",
        $payment->id )->status_is(200);

    isnt status_of( $studio, $payment ), 'completed', 'the payment is not completed';
    is scalar continuations($run), 0, 'no job continues the run';
    is step_of( $studio, $run ), 'before', 'and the run has not moved past the payment';
};

subtest 'foreign or repointed offer version stamp refused' => sub {
    my $other = seller();
    my %row = ( user_id => $studio->{buyer}->id, amount_cents => 1060,
                metadata => { tenant_slug => $studio->{slug} } );

    ok !eval { Registry::DAO::Payment->create( $studio->{db},
            { %row, offer_version_id => $other->{version}->id } ); 1 },
        "a stamp naming another tenant's offer version is refused";
    like $@, qr/payments_offer_version_id_fkey/, 'by the foreign key';
    ok !eval { Registry::DAO::Payment->create( $studio->{db},
            { %row, offer_version_id => '00000000-0000-4000-8000-000000000000' } ); 1 },
        'and one naming no offer version';

    refused_without_charge( $studio,
        owed_run( $studio, offer_version_id => $other->{version}->id ), {},
        "a run owing under another tenant's offer version" );

    my $payment = pay_step($studio)->owed_payment( $studio->{db}, owed_run($studio) )->{payment};
    my $resource = Registry::DAO::Resource->create( $studio->{db}, { name => 'Other seat', kind => 'unbounded' } );
    my $elsewhere = Registry::DAO::Offer->create( $studio->{db}, { name => 'Other' } )
        ->draft( $studio->{db}, offer_terms( $resource->id ) )->publish( $studio->{db} );
    for my $to ( $elsewhere->id, undef ) {
        ok !eval { $studio->{db}->update( 'payments', { offer_version_id => $to },
                { id => $payment->id } ); 1 },
            're-pointing the stamp ' . ( $to ? 'to another version' : 'to nothing' ) . ' is refused';
        like $@, qr/keeps the offer version it was sold under/, 'by the stamp trigger';
    }
    is Registry::DAO::Payment->find( $studio->{db}, { id => $payment->id } )->offer_version_id,
        $studio->{version}->id, 'the stamp is unchanged';
};

done_testing;
