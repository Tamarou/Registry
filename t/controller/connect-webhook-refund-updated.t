# ABOUTME: refund.updated on the Connect endpoint settles a refund Registry made that Stripe answered pending.
# ABOUTME: Succeeded is counted once; failed or canceled is recorded and alerts staff; anyone else's refund stays stored unapplied.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::PricingProbe qw( state_platform_terms );
use Test::Registry::Async qw( settle );
use Test::Registry::StripeWebhook;
use Registry::DAO::Tenant;
use Registry::DAO::Family;
use Registry::DAO::Payment;
use Registry::DAO::Enrollment;
use Registry::Service::Stripe;
use Mojo::Promise;

local $ENV{STRIPE_SECRET_KEY}             = 'sk_test_fake_for_refund_updated';
local $ENV{STRIPE_WEBHOOK_SECRET}         = 'whsec_test_fake_for_refund_updated';
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_test_fake_for_refund_updated_connect';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

my @logs;
$t->app->log->unsubscribe('message');
$t->app->log->level('info');
$t->app->log->on(message => sub ($log, $level, @lines) { push @logs, [ $level, "@lines" ] });

my $admin = $dao->create(User => { username => 'ru_admin', name => 'A',
    user_type => 'admin', email => 'ru_admin@test.local' });

my $slug    = "ru_$$";
my $account = "acct_ru_$$";
Registry::DAO::Tenant->provision($db, {
    name => "RU $$", slug => $slug, users => [$admin],
    stripe_connect_account_id => $account,
    stripe_charges_enabled => 1, stripe_details_submitted => 1 });
my $tdb = Registry::DAO->new(url => $test_db->uri, schema => $slug)->db;
state_platform_terms( $db, $slug, { rate => 0 } );

my $session = Registry::DAO::Session->create($tdb, { name => 'RU Week',
    start_date => '2026-01-01', end_date => '2026-12-31',
    status => 'published', capacity => 10, metadata => {} });
my $parent = Registry::DAO::User->create($tdb, { username => 'ru_parent',
    name => 'P', user_type => 'parent', email => 'ru_p@test.local' });

# A paid seat whose drop was approved for 4000 of its 10000.
my $kids = 0;
sub a_dropped_seat () {
    my $child = Registry::DAO::Family->add_child($tdb, $parent->id, {
        child_name => 'RU Kid ' . ++$kids, birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' } });
    my $p = Registry::DAO::Payment->create($tdb, {
        user_id => $parent->id, amount_cents => 10000, status => 'completed',
        stripe_payment_intent_id => "pi_ru_$kids",
        metadata => { tenant_slug => $slug, stripe_account_id => $account,
            enrollment_items => [ { session_id => $session->id, child_id => $child->id } ] } });
    my $enrollment = Registry::DAO::Enrollment->create($tdb, {
        session_id => $session->id, student_id => $child->id, parent_id => $parent->id,
        payment_id => $p->id, status => 'cancelled',
        refund_status => 'pending', refund_amount_cents => 4000 });
    return ( Registry::DAO::Payment->find($tdb, { id => $p->id }), $enrollment );
}

# Stripe answers the refund pending, through the production refund call.
sub refund_pending ($payment, $refund_id, %args) {
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_refund_async = sub ($s, $p) {
        Mojo::Promise->resolve({ id => $refund_id, amount => $p->{amount}, status => 'pending' });
    };
    settle( $payment->refund_async( $tdb, { reason => 'requested_by_customer', %args } ) );
}

sub post_refund_updated ($refund_id, $status, %object) {
    my $event = {
        type    => 'refund.updated',
        account => $account,
        data    => { object => { id => $refund_id, object => 'refund', status => $status, %object } },
    };
    my $tx = Test::Registry::StripeWebhook::post_connect($t, $event);
    return ( $tx, $event->{id} );
}

sub event_row ($event_id) {
    $db->select('registry.webhook_events', [qw( processed_at payload )],
        { stripe_event_id => $event_id })->hash;
}
sub payment_row ($payment) { $tdb->select('payments', '*', { id => $payment->id })->expand->hash }
sub refund_status_of ($enrollment) {
    $tdb->select('enrollments', ['refund_status'], { id => $enrollment->id })->hash->{refund_status};
}
sub alerts_about ($refund_id) {
    $tdb->query( q{SELECT count(*) FROM notifications WHERE type = 'general' AND message LIKE ?},
        "%$refund_id%" )->array->[0];
}

subtest 'a pending refund that succeeds is recorded once' => sub {
    my ( $payment, $enrollment ) = a_dropped_seat();
    refund_pending( $payment, 're_ru_ok', amount_cents => 4000,
        idempotency_key => $payment->drop_refund_key( $enrollment->id ) );
    is payment_row($payment)->{refunded_cents}, 0, 'held while pending';

    my ( $tx, $event_id ) = post_refund_updated( 're_ru_ok', 'succeeded', amount => 4000 );
    $tx->status_is(200)->content_is('OK');

    my $row = payment_row($payment);
    is $row->{refunded_cents}, 4000, 'the refund is counted';
    is $row->{status}, 'partially_refunded', 'and the payment status follows it';
    is refund_status_of($enrollment), 'processed', 'the dropped seat reads processed';
    ok event_row($event_id)->{processed_at}, 'the event is applied';

    Test::Registry::StripeWebhook::post_connect($t, {
        id => $event_id, type => 'refund.updated', account => $account,
        data => { object => { id => 're_ru_ok', object => 'refund', status => 'succeeded' } },
    })->status_is(200)->content_is('OK (duplicate)', 'a redelivery is a duplicate');

    my ( $again, $again_id ) = post_refund_updated( 're_ru_ok', 'succeeded', amount => 4000 );
    $again->status_is(200);
    is payment_row($payment)->{refunded_cents}, 4000, 'a later event for it counts nothing again';
    is event_row($again_id)->{processed_at}, undef, 'and is stored unapplied, as any Stripe move';
};

subtest 'a pending refund that fails is recorded failed and staff are alerted' => sub {
    for my $answer (qw( failed canceled )) {
        my ( $payment, $enrollment ) = a_dropped_seat();
        refund_pending( $payment, "re_ru_$answer", amount_cents => 4000,
            idempotency_key => $payment->drop_refund_key( $enrollment->id ) );

        @logs = ();
        my ( $tx, $event_id ) = post_refund_updated( "re_ru_$answer", $answer,
            amount => 4000, failure_reason => "lost\nERROR forged" );
        $tx->status_is(200)->content_is('OK');

        my $row = payment_row($payment);
        is $row->{refunded_cents}, 0, "$answer: nothing is counted as returned";
        is $row->{status}, 'completed', "$answer: the payment status does not move";
        is $row->{metadata}{refund_status}, $answer, "$answer: the refund is recorded $answer";
        like $row->{metadata}{refund_last_failure}{message} // '', qr/re_ru_\Q$answer\E/,
            "$answer: the runbook's failure record names it";
        is refund_status_of($enrollment), 'pending', "$answer: the seat's refund is still owed";
        is alerts_about("re_ru_$answer"), 1, "$answer: the tenant admin is alerted";
        ok event_row($event_id)->{processed_at}, "$answer: the event is applied";
        ok !scalar( grep { $_->[1] =~ /\nERROR forged/ } @logs ),
            "$answer: Stripe's text cannot forge a log line";
    }
};

subtest 'a pending capacity refund that succeeds settles its increment' => sub {
    my ( $payment ) = a_dropped_seat();
    $payment->record_capacity_obligation( $tdb, 3000, ['ru-demoted'] );
    my ($inc) = @{ $payment->unsettled_refund_increments($tdb) };
    refund_pending( $payment, 're_ru_capacity', amount_cents => $inc->{cents}, increment => 1,
        idempotency_key => $payment->capacity_refund_key( $inc->{seq} ) );
    is payment_row($payment)->{refund_owed_cents}, 3000, 'owed while pending';

    my ( $tx ) = post_refund_updated( 're_ru_capacity', 'succeeded', amount => 3000 );
    $tx->status_is(200);

    my $row = payment_row($payment);
    is $row->{refund_owed_cents}, 0, 'the debt is discharged';
    is $row->{refunded_cents}, 3000, 'and counted as returned, once';
    is $row->{status}, 'partially_refunded', 'and the status follows it';
    is scalar @{ $payment->unsettled_refund_increments($tdb) }, 0, 'nothing is left to send';
};

done_testing;
