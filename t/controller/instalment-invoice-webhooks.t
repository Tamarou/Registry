#!/usr/bin/env perl
# ABOUTME: Each instalment invoice marks exactly one owed row, and a failure does not cost a child their place.
# ABOUTME: Matched by position, not amount -- only the last instalment differs, so amounts do not distinguish.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is ok like is_deeply subtest diag )];
defer { done_testing };

use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::StripeWebhook;
use Registry::DAO::Payment;
use Registry::DAO::Tenant;

local $ENV{STRIPE_WEBHOOK_SECRET}         = 'whsec_local_platform_instalments';
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_local_connect_instalments';

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
$ENV{DB_URL} = $t_db->uri;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $dao } );

# A tenant whose Stripe account the schedules live on: the Connect endpoint
# finds it from event.account, and its instalment rows live in its own schema.
sub tenant ( $name ) {
    my $slug  = "inst_${name}_$$";
    my $admin = $dao->create( User => { username => "inst_${name}_admin_$$", user_type => 'admin' } );
    Registry::DAO::Tenant->provision( $dao->db, {
        name  => "Instalment $name $$",
        slug  => $slug,
        users => [$admin],
        stripe_connect_account_id => "acct_inst_${name}_$$",
    } );
    my $tdao = $dao->connect_schema($slug);
    my $user = $tdao->create( User => { username => "inst_${name}_parent_$$", user_type => 'parent' } );
    return { slug => $slug, account => "acct_inst_${name}_$$", db => $tdao->db, user => $user };
}

my $A = tenant('a');

my $SCHED = 'sub_sched_probe';

# The set as schedule_remaining_instalments leaves it: instalment one paid, the
# rest owed, all sharing one schedule id.
sub build_set ( $tenant = $A ) {
    my $db = $tenant->{db};
    $db->delete( 'payments', { stripe_schedule_id => $SCHED } );

    my @amounts = ( 3333, 3333, 3334 );
    my @ids;
    for my $i ( 1 .. 3 ) {
        my $row = $db->insert( 'payments', {
            user_id            => $tenant->{user}->id,
            amount_cents       => $amounts[ $i - 1 ],
            currency           => 'USD',
            status             => $i == 1 ? 'completed' : 'pending',
            instalment_seq     => $i,
            instalment_count   => 3,
            due_date           => sprintf( '2026-%02d-01', 5 + $i ),
            stripe_schedule_id => $SCHED,
            metadata           => { -json => {} },
        }, { returning => 'id' } )->hash;
        push @ids, $row->{id};
    }
    return @ids;
}

# Signed and posted to the Connect endpoint, as Stripe sends an invoice from a
# schedule on the tenant's own account.
sub deliver ( $type, $invoice, $tenant = $A ) {
    Test::Registry::StripeWebhook::post_connect( $t, {
        type => $type, account => $tenant->{account}, data => { object => $invoice } } )
        ->status_is(200);
}

sub statuses ( $tenant = $A ) {
    return $tenant->{db}->query( q{
        SELECT status FROM payments WHERE stripe_schedule_id = ? ORDER BY instalment_seq
    }, $SCHED )->arrays->flatten->to_array;
}

subtest 'connect instalment invoice marks the tenant instalment' => sub {
    build_set();

    deliver( 'invoice.paid', { schedule => $SCHED, payment_intent => 'pi_conn_two' } );
    is_deeply statuses(), [qw( completed completed pending )],
        "the earliest owed row in the account's tenant is completed";

    deliver( 'invoice.paid', { schedule => $SCHED, payment_intent => 'pi_conn_two' } );
    is_deeply statuses(), [qw( completed completed pending )],
        'a redelivery does not advance the set';

    deliver( 'invoice.payment_failed', {
        schedule => $SCHED, payment_intent => 'pi_conn_three' } );
    is_deeply statuses(), [qw( completed completed failed )],
        'and a failed invoice marks the next owed row failed';
};

subtest 'a paid invoice completes the earliest owed instalment' => sub {
    build_set();
    is_deeply statuses(), [qw( completed pending pending )], 'two still owed';

    deliver( 'invoice.paid', {
        schedule => $SCHED, payment_intent => 'pi_two', amount_paid => 3333 } );

    is_deeply statuses(), [qw( completed completed pending )],
        'the second is paid, the third is not';

    deliver( 'invoice.paid', {
        schedule => $SCHED, payment_intent => 'pi_three', amount_paid => 3334 } );

    is_deeply statuses(), [qw( completed completed completed )], 'and then the third';
};

# A redelivery is not another instalment. Stripe retries webhooks, and an
# invoice arriving twice must not advance the set twice -- which would leave the
# family recorded as having paid money they never sent.
subtest 'a redelivered invoice advances nothing' => sub {
    build_set();

    deliver( 'invoice.paid', { schedule => $SCHED, payment_intent => 'pi_two' } );
    is_deeply statuses(), [qw( completed completed pending )], 'the second is paid';

    deliver( 'invoice.paid', { schedule => $SCHED, payment_intent => 'pi_two' } );
    is_deeply statuses(), [qw( completed completed pending )],
        'and the same invoice again changes nothing';
};

subtest 'a failed instalment is recorded, and the child keeps their place' => sub {
    my @ids = build_set();

    deliver( 'invoice.payment_failed', {
        schedule       => $SCHED,
        payment_intent => 'pi_two_failed',
        last_finalization_error => { message => 'Your card was declined.' },
    } );

    is_deeply statuses(), [qw( completed failed pending )],
        'the second instalment is failed, the third still pending';

    my $failed = Registry::DAO::Payment->find( $A->{db}, { id => $ids[1] } );
    like $failed->error_message, qr/declined/,
        'and the reason is on the row, for Morgan to read';

    # keep_and_flag. A child who has been attending for six weeks does not lose
    # their place over an expired card; the debt stands and Morgan decides. She
    # knows her families, and a seat returned to a waitlist cannot be given back.
    my $enrolments = $A->{db}->query(
        q{SELECT count(*) FROM enrollments WHERE status = 'cancelled'} )->array->[0];
    is $enrolments, 0, 'no enrolment was cancelled by the failure';
};

subtest 'a retry after a failure completes the same instalment' => sub {
    build_set();

    deliver( 'invoice.payment_failed', {
        schedule => $SCHED, payment_intent => 'pi_two_failed' } );
    is_deeply statuses(), [qw( completed failed pending )], 'failed';

    # A failed row is still owed, so Stripe's own retry lands on it rather than
    # skipping to the third instalment and leaving the second owed forever.
    deliver( 'invoice.paid', { schedule => $SCHED, payment_intent => 'pi_two_retry' } );
    is_deeply statuses(), [qw( completed completed pending )],
        'the retry settles the instalment that failed, not the next one';
};

# The studio's own invoicing on its own account is not Registry's to record, and
# reading it as tenant billing would move a tenant's status on a parent's card.
subtest 'unmatched connect invoice changes nothing and skips billing' => sub {
    build_set();

    for my $type (qw( invoice.paid invoice.payment_failed )) {
        my $event = { type => $type, account => $A->{account},
            data => { object => { schedule => 'sub_sched_studio_own', payment_intent => "pi_studio_$type" } } };
        Test::Registry::StripeWebhook::post_connect( $t, $event )
            ->status_is(200)->content_is('OK');

        is_deeply statuses(), [qw( completed pending pending )], "$type changes no instalment";
        is $dao->db->select( 'registry.subscription_events', ['id'],
            { stripe_event_id => $event->{id} } )->rows, 0, 'and never reaches tenant billing';
    }
};

# The account picks the schema, so a schedule id that only another tenant
# holds is nobody's here -- whichever studio's invoice carries it.
subtest 'invoice matching only another tenant changes neither' => sub {
    state $B = tenant('b');
    $A->{db}->delete( 'payments', { stripe_schedule_id => $SCHED } );
    build_set($B);

    deliver( 'invoice.paid', { schedule => $SCHED, payment_intent => 'pi_cross_tenant' } );

    is_deeply statuses($B), [qw( completed pending pending )], 'the other tenant is untouched';
    is_deeply statuses($A), [], 'and the tenant the account names has nothing to mark';
};

# Stripe does not promise delivery order. A failed attempt reported after the
# retry that paid is history, not news.
subtest 'failed after paid never reverts a completed instalment' => sub {
    build_set();

    deliver( 'invoice.paid', {
        id => 'in_two', schedule => $SCHED, payment_intent => 'pi_two_late' } );
    deliver( 'invoice.payment_failed', {
        id => 'in_two', schedule => $SCHED, payment_intent => 'pi_two_late' } );

    is_deeply statuses(), [qw( completed completed pending )],
        'the paid instalment stays completed and the next is not failed';
};

# Instalment invoices come from the seller's account now. One reaching the
# platform endpoint is the platform's own billing, never a family's instalment.
subtest 'platform endpoint no longer marks instalments' => sub {
    build_set();
    my $parent = $dao->create( User => { username => "inst_registry_parent_$$", user_type => 'parent' } );
    my $reg = { db => $dao->db, user => $parent };
    build_set($reg);

    Test::Registry::StripeWebhook::post_connect( $t, {
        type => 'invoice.paid',
        data => { object => { schedule => $SCHED, payment_intent => 'pi_platform_inst' } } },
        path => '/webhooks/stripe', secret => $ENV{STRIPE_WEBHOOK_SECRET} )->status_is(200);

    is_deeply statuses($reg), [qw( completed pending pending )], 'no registry instalment is marked';
    is_deeply statuses(),     [qw( completed pending pending )], 'nor any tenant instalment';
    $dao->db->delete( 'payments', { stripe_schedule_id => $SCHED } );
};

# The seller owns the account, so they own every subscription's metadata on it
# and can write our schedule id there. Only an id Stripe sets ties an invoice
# to the schedule Registry stored.
subtest 'seller metadata naming a schedule marks nothing' => sub {
    build_set();

    deliver( 'invoice.paid', {
        subscription_details => { metadata => { schedule => $SCHED } },
        payment_intent       => 'pi_seller_own' } );

    is_deeply statuses(), [qw( completed pending pending )], 'no instalment is marked paid';
};

$t_db->cleanup_test_database;
