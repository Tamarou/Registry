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
use Registry::DAO::Payment;
use Registry::Controller::Webhooks;

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
my $db   = $dao->db;
$ENV{DB_URL} = $t_db->uri;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $dao } );

my $user = $dao->create( User => { username => 'instalment_parent', user_type => 'parent' } );

my $SCHED = 'sub_sched_probe';

# The set as schedule_remaining_instalments leaves it: instalment one paid, the
# rest owed, all sharing one schedule id.
sub build_set () {
    $db->delete( 'payments', { stripe_schedule_id => $SCHED } );

    my @amounts = ( 3333, 3333, 3334 );
    my @ids;
    for my $i ( 1 .. 3 ) {
        my $row = $db->insert( 'payments', {
            user_id            => $user->id,
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

# The controller's own handler, driven directly: the signature verification and
# dedup around it are t/controller/payment-intent-webhook.t's subject, and going
# through them here would test those instead of this.
# build_controller gives a bare Mojolicious::Controller; the webhook methods
# live on Registry::Controller::Webhooks, so the controller is built as that
# class rather than reached through a route.
sub webhooks_controller () {
    my $c = $t->app->build_controller;
    return bless $c, 'Registry::Controller::Webhooks';
}

sub deliver ( $type, $invoice ) {
    webhooks_controller()
        ->_process_instalment_invoice( $db, { type => $type, data => { object => $invoice } } );
}

sub statuses () {
    return $db->query( q{
        SELECT status FROM payments WHERE stripe_schedule_id = ? ORDER BY instalment_seq
    }, $SCHED )->arrays->flatten->to_array;
}

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

    my $failed = Registry::DAO::Payment->find( $db, { id => $ids[1] } );
    like $failed->error_message, qr/declined/,
        'and the reason is on the row, for Morgan to read';

    # keep_and_flag. A child who has been attending for six weeks does not lose
    # their place over an expired card; the debt stands and Morgan decides. She
    # knows her families, and a seat returned to a waitlist cannot be given back.
    my $enrolments = $db->query(
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

subtest 'an invoice for a schedule Registry does not know is left alone' => sub {
    build_set();

    my $c = webhooks_controller();
    ok !$c->_invoice_is_instalment( $db,
        { data => { object => { schedule => 'sub_sched_someone_elses' } } } ),
        'not recognised as an instalment';

    # Which matters because the branch it would otherwise fall into reads an
    # invoice as OUR subscription being paid, and would move a tenant's billing
    # status on the strength of a parent's card.
    ok !$c->_invoice_is_instalment( $db, { data => { object => {} } } ),
        'and an invoice with no schedule at all is not one either';
};

$t_db->cleanup_test_database;
