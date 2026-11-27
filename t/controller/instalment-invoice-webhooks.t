#!/usr/bin/env perl
# ABOUTME: Each instalment invoice marks exactly one owed row, and a failure does not cost a child their place.
# ABOUTME: Keyed on the invoice id; a new invoice takes the earliest pending row by position, not amount.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is ok like is_deeply subtest diag )];
use Test::Registry::Fork qw( forget_inherited_handles reap );
defer { done_testing };

use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::StripeWebhook;
use Test::Registry::InstalmentCheckout qw( instalment_checkout );
use Registry::DAO::Payment;
use Registry::DAO::Tenant;
use Registry::Service::Stripe;
use Mojo::Promise;
use Mojo::Pg;
use POSIX ();
use Registry::Controller::Webhooks;

local $ENV{STRIPE_WEBHOOK_SECRET}         = 'whsec_local_platform_instalments';
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_local_connect_instalments';

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
$ENV{DB_URL} = $t_db->uri;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $dao } );

my @logs;
$t->app->log->unsubscribe('message');
$t->app->log->level('info');
$t->app->log->on( message => sub ( $log, $level, @lines ) { push @logs, [ $level, "@lines" ] } );

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
my $SUB   = 'sub_inst_probe';

# An invoice names its subscription, and the subscription names the schedule
# that made it (Stripe sets that field; the seller cannot). The lookup is
# answered here, recorded with the account it was asked on, and never sent to
# Stripe. A subscription not listed is one Stripe could not return. The
# schedule is expanded, as the webhook asks for it.
my %SUBSCRIPTIONS = (
    $SUB                   => { id => $SUB, schedule => { id => $SCHED, metadata => {} } },
    sub_studio_own         => { id => 'sub_studio_own',
        schedule => { id => 'sub_sched_studio_own', metadata => {} } },
    sub_studio_unscheduled => { id => 'sub_studio_unscheduled', schedule => undef },
);
my @lookups;
no warnings 'redefine';
local *Registry::Service::Stripe::retrieve_subscription_async = sub ( $s, $id, $params = {} ) {
    push @lookups, [ $s->stripe_account, $id, $params ];
    my $sub = $SUBSCRIPTIONS{$id}
        or return Mojo::Promise->reject("Stripe invalid_request_error: No such subscription: '$id'");
    return Mojo::Promise->resolve($sub);
};
use warnings 'redefine';

# The platform offer version instalment one was priced under (Solo v1), snapshotted onto every row.
my $PLAN = '00000000-0000-0000-0003-000000000001';

# A child's paid checkout in three parts: the cart charge took part one, with
# its fee recorded under $PLAN.
sub checkout ( $tenant, %o ) {
    my $c = instalment_checkout( $tenant->{db}, parent => $tenant->{user}->id, %o );
    $tenant->{db}->update( 'payments', { platform_fee_cents => 83, platform_offer_version_id => $PLAN },
        { id => $c->{payment}->id } );
    return $c;
}

# The set as schedule_instalments_for leaves it: parts two and three owed on
# the child's entitlement, sharing one schedule id and carrying the seller
# account and plan the checkout charge was made under. One checkout per
# tenant unless $c names another; each call replaces the rows.
sub build_set ( $tenant = $A, $c = $tenant->{checkout} //= checkout($tenant) ) {
    my $db = $tenant->{db};
    $db->delete( 'payments', { stripe_schedule_id => $SCHED } );

    my @amounts = ( 3333, 3333, 3334 );
    my @ids;
    for my $i ( 2 .. 3 ) {
        my $row = $db->insert( 'payments', {
            user_id            => $tenant->{user}->id,
            amount_cents       => $amounts[ $i - 1 ],
            currency           => 'USD',
            status             => 'pending',
            instalment_seq     => $i,
            instalment_count   => 3,
            due_date           => sprintf( '2026-%02d-01', 5 + $i ),
            stripe_schedule_id => $SCHED,
            entitlement_id     => $c->{entitlement}->id,
            metadata           => { -json => {
                instalment_of             => $c->{payment}->id,
                stripe_account_id         => $tenant->{account},
                platform_offer_version_id => $PLAN,
                platform_payment_plan_id  => 'revenue_share',
            } },
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

# A schedule's invoice as Stripe sends it at 2024-12-18.acacia. A retry after a
# failure is the same invoice on the same payment intent.
sub invoice ( $id, $intent, %more ) {
    return {
        id => $id, object => 'invoice', subscription => $SUB,
        payment_intent => $intent, billing_reason => 'subscription_cycle',
        amount_due => 3333, amount_paid => 0, status => 'open', %more,
    };
}

sub statuses ( $tenant = $A ) {
    return $tenant->{db}->query( q{
        SELECT status FROM payments WHERE stripe_schedule_id = ? ORDER BY instalment_seq
    }, $SCHED )->arrays->flatten->to_array;
}

subtest 'connect instalment invoice marks the tenant instalment' => sub {
    build_set();

    deliver( 'invoice.paid', invoice( 'in_conn_two', 'pi_conn_two' ) );
    is_deeply statuses(), [qw( completed pending )],
        "the earliest owed row in the account's tenant is completed";

    deliver( 'invoice.paid', invoice( 'in_conn_two', 'pi_conn_two' ) );
    is_deeply statuses(), [qw( completed pending )],
        'a redelivery does not advance the set';

    deliver( 'invoice.payment_failed', invoice( 'in_conn_three', 'pi_conn_three' ) );
    is_deeply statuses(), [qw( completed failed )],
        'and a failed invoice marks the next owed row failed';
};

subtest 'a paid invoice completes the earliest owed instalment' => sub {
    build_set();
    is_deeply statuses(), [qw( pending pending )], 'two still owed';

    deliver( 'invoice.paid', invoice( 'in_two', 'pi_two', amount_paid => 3333 ) );

    is_deeply statuses(), [qw( completed pending )],
        'the second is paid, the third is not';

    deliver( 'invoice.paid', invoice( 'in_three', 'pi_three', amount_paid => 3334 ) );

    is_deeply statuses(), [qw( completed completed )], 'and then the third';
};

sub fee_and_plan ( $id, $tenant = $A ) {
    return $tenant->{db}->query(
        'SELECT platform_fee_cents, platform_offer_version_id FROM payments WHERE id = ?',
        $id )->array;
}

sub revenue_for ( $tenant = $A ) {
    my ($row) = grep { $_->{slug} eq $tenant->{slug} }
        @{ Registry::DAO::Tenant->platform_revenue( $dao->db )->{tenants} };
    return $row;
}

# Acacia invoices carry the fee Stripe took at the top level.
subtest 'a paid instalment invoice records its application fee and snapshotted plan' => sub {
    my @ids = build_set();

    deliver( 'invoice.paid', invoice( 'in_fee', 'pi_fee', application_fee_amount => 83 ) );

    is_deeply fee_and_plan( $ids[0] ), [ 83, $PLAN ],
        "the invoice's fee and instalment one's plan are on the row";
    is_deeply fee_and_plan( $ids[1] ), [ undef, undef ], 'the next owed row is untouched';
};

# Stripe omits a zero application fee; on a seller's account that took nothing.
subtest 'a paid instalment invoice with no application fee records zero' => sub {
    my @ids = build_set();

    deliver( 'invoice.paid', invoice( 'in_no_fee', 'pi_no_fee' ) );

    is_deeply fee_and_plan( $ids[0] ), [ 0, $PLAN ], 'zero, under the snapshotted plan';
};

# Stripe's retry of a failed invoice is the delivery that takes the fee.
subtest 'payment_failed then invoice.paid records the fee on that row' => sub {
    my @ids = build_set();

    deliver( 'invoice.payment_failed', invoice( 'in_two', 'pi_two' ) );
    deliver( 'invoice.paid', invoice( 'in_two', 'pi_two', application_fee_amount => 50 ) );

    is_deeply fee_and_plan( $ids[0] ), [ 50, $PLAN ], "the retry's fee is on the row that failed";
    is_deeply fee_and_plan( $ids[1] ), [ undef, undef ], 'and the next owed row is untouched';
};

# Recorded once, by the delivery that completed the row.
subtest 'a redelivered invoice.paid with a different fee leaves the first fee' => sub {
    my @ids = build_set();

    deliver( 'invoice.paid', invoice( 'in_two', 'pi_two', application_fee_amount => 50 ) );
    deliver( 'invoice.paid', invoice( 'in_two', 'pi_two', application_fee_amount => 99 ) );

    is_deeply fee_and_plan( $ids[0] ), [ 50, $PLAN ], 'the first fee stands';
};

subtest 'platform_revenue counts a paid instalment as recorded' => sub {
    build_set();

    deliver( 'invoice.paid', invoice( 'in_rev', 'pi_rev', application_fee_amount => 83 ) );

    my $rev = revenue_for();
    is $rev->{charges},    2,   'both completed instalments are counted';
    is $rev->{fees_cents}, 166, 'with both fees';
    is $rev->{unrecorded}, 0,   'and neither reads as a gap';
};

# A redelivery is not another instalment. Stripe retries webhooks, and an
# invoice arriving twice must not advance the set twice -- which would leave the
# family recorded as having paid money they never sent.
subtest 'a redelivered invoice advances nothing' => sub {
    build_set();

    deliver( 'invoice.paid', invoice( 'in_two', 'pi_two' ) );
    is_deeply statuses(), [qw( completed pending )], 'the second is paid';

    deliver( 'invoice.paid', invoice( 'in_two', 'pi_two' ) );
    is_deeply statuses(), [qw( completed pending )],
        'and the same invoice again changes nothing';
};

subtest 'a failed instalment is recorded, and the child keeps their place' => sub {
    my @ids = build_set();

    deliver( 'invoice.payment_failed', invoice( 'in_two', 'pi_two_failed',
        last_finalization_error => { message => 'Your card was declined.' } ) );

    is_deeply statuses(), [qw( failed pending )],
        'the second instalment is failed, the third still pending';

    my $failed = Registry::DAO::Payment->find( $A->{db}, { id => $ids[0] } );
    like $failed->error_message, qr/declined/,
        'and the reason is on the row, for Morgan to read';

    # keep_and_flag. A child who has been attending for six weeks does not lose
    # their place over an expired card; the debt stands and Morgan decides. She
    # knows her families, and a seat returned to a waitlist cannot be given back.
    my $enrolments = $A->{db}->query(
        q{SELECT count(*) FROM enrollments WHERE status = 'cancelled'} )->array->[0];
    is $enrolments, 0, 'no enrolment was cancelled by the failure';
};

# Stripe retries a failed invoice and reports each attempt. Morgan reads the
# latest reason, not the first.
subtest 'a second failure of one invoice keeps the latest reason' => sub {
    my @ids = build_set();

    deliver( 'invoice.payment_failed', invoice( 'in_two', 'pi_two',
        last_finalization_error => { message => 'Your card was declined.' } ) );
    deliver( 'invoice.payment_failed', invoice( 'in_two', 'pi_two',
        last_finalization_error => { message => 'Your card has expired.' } ) );

    is_deeply statuses(), [qw( failed pending )], 'the row stays failed';
    like( Registry::DAO::Payment->find( $A->{db}, { id => $ids[0] } )->error_message,
        qr/expired/, "with the second attempt's reason" );
};

subtest 'a retry after a failure completes the same instalment' => sub {
    build_set();

    deliver( 'invoice.payment_failed', invoice( 'in_two', 'pi_two_failed' ) );
    is_deeply statuses(), [qw( failed pending )], 'failed';

    # A failed row is still owed, so Stripe's own retry lands on it rather than
    # skipping to the third instalment and leaving the second owed forever.
    deliver( 'invoice.paid', invoice( 'in_two', 'pi_two_retry' ) );
    is_deeply statuses(), [qw( completed pending )],
        'the retry settles the instalment that failed, not the next one';
};

# Stripe retries an invoice on the payment intent it already tried, so the paid
# event carries the intent the failure stored on the row.
subtest 'payment_failed then invoice.paid on the same intent completes the same row' => sub {
    build_set();

    deliver( 'invoice.payment_failed', invoice( 'in_two', 'pi_two' ) );
    is_deeply statuses(), [qw( failed pending )], 'failed';

    deliver( 'invoice.paid', invoice( 'in_two', 'pi_two', amount_paid => 3333, status => 'paid' ) );
    is_deeply statuses(), [qw( completed pending )],
        'the retry completes the row that failed';
};

# No payment intent means no charge was attempted, so nothing failed: the row
# stays owed, and redelivering the event marks nothing either.
subtest 'payment_failed with no payment_intent delivered twice marks no row failed' => sub {
    build_set();

    deliver( 'invoice.payment_failed', invoice( 'in_no_intent', undef ) ) for 1 .. 2;
    is_deeply statuses(), [qw( pending pending )], 'no row is failed';
};

# A failure with no intent still names its month: the invoice is bound to the
# row it would have charged, so a later month's invoice cannot take that row.
subtest 'payment_failed with no intent binds its row, and month three paid takes month three' => sub {
    my @ids = build_set();

    deliver( 'invoice.payment_failed', invoice( 'in_month_two', undef ) );
    is_deeply statuses(), [qw( pending pending )], 'no row is failed';

    deliver( 'invoice.paid', invoice( 'in_month_three', 'pi_month_three' ) );
    is_deeply statuses(), [qw( pending completed )],
        "month three's invoice completes month three, month two stays owed";

    is $A->{db}->query( q{SELECT metadata->>'stripe_invoice_id' FROM payments WHERE id = ?},
        $ids[0] )->array->[0], 'in_month_two', "and month two's invoice is bound to its row";
};

# Stripe delivers the failure and the paid retry of one invoice concurrently.
# Neither has tagged a row when both look, so without serialising on the
# schedule both fall back to the earliest owed row: paid completes row two and
# the failure, re-checking after paid commits, moves on and fails row three.
#
# Two real connections and a fork: one process cannot produce the interleaving.
# The child runs the paid invoice through the real handler in a transaction it
# holds open until the failed delivery is seen waiting on it, then commits.
subtest 'concurrent payment_failed and invoice.paid for one invoice mark one row' => sub {
    build_set();

    pipe( my $parent_reads, my $child_writes ) or die "pipe: $!";
    my $pid = fork() // die "fork: $!";
    unless ($pid) {
        forget_inherited_handles();
        close $parent_reads;
        my $ok = eval {
            # The Mojo::Pg must outlive the handle -- ->db holds a weak reference.
            my $pg  = Mojo::Pg->new( $t_db->uri )->search_path( [ $A->{slug}, 'public' ] );
            my $cdb = $pg->db;
            my $tx  = $cdb->begin;
            Registry::Controller::Webhooks->new( app => $t->app )->_process_instalment_invoice(
                $cdb, { type => 'invoice.paid', data => { object => invoice( 'in_race', 'pi_race' ) } },
                $SCHED );
            print $child_writes "locked\n";
            $child_writes->flush;

            # Commit only once the failed delivery is blocked behind us.
            my $me = $cdb->query('SELECT pg_backend_pid()')->array->[0];
            my $waited;
            for ( 1 .. 100 ) {
                last if $waited = $pg->db->query(
                    'SELECT 1 FROM pg_stat_activity WHERE ? = ANY(pg_blocking_pids(pid))', $me )->rows;
                select undef, undef, undef, 0.1;
            }
            $tx->commit;
            $waited;
        };
        POSIX::_exit( $ok ? 0 : 1 );
    }

    close $child_writes;
    readline $parent_reads;
    deliver( 'invoice.payment_failed', invoice( 'in_race', 'pi_race' ) );
    reap($pid);

    is $? >> 8, 0, 'the failed delivery waited on the paid transaction';
    is_deeply statuses(), [qw( completed pending )],
        'the invoice completes one row and fails none';
};

# An invoice that will never be charged leaves its month owed. Left pending,
# the debt goes quiet; failed, it heads Morgan's dashboard with the reason.
subtest 'a voided or uncollectible instalment invoice is flagged on the dashboard' => sub {
    my @ids = build_set();

    # Bound by no-intent failures, as a schedule's unchargeable invoice is.
    deliver( 'invoice.payment_failed', invoice( 'in_void', undef ) );
    deliver( 'invoice.payment_failed', invoice( 'in_uncollectible', undef ) );
    is_deeply statuses(), [qw( pending pending )], 'both bound, both still pending';

    deliver( 'invoice.voided', invoice( 'in_void', undef, status => 'void' ) );
    deliver( 'invoice.marked_uncollectible', invoice( 'in_uncollectible', undef, status => 'uncollectible' ) );
    is_deeply statuses(), [qw( failed failed )], 'each marks its own row failed';

    my %owed = map { $_->{id} => $_ }
        @{ Registry::DAO::Payment->outstanding_instalments( $A->{db} ) };
    is $owed{ $ids[0] }{status}, 'failed', 'the voided month is on the dashboard as failed';
    like $owed{ $ids[0] }{error_message}, qr/voided/, 'with why';
    like $owed{ $ids[1] }{error_message}, qr/uncollectible/, 'and so is the uncollectible one';
};

subtest 'a void names only its own invoice, and never a paid one' => sub {
    build_set();

    deliver( 'invoice.voided', invoice( 'in_never_seen', undef, status => 'void' ) );
    is_deeply statuses(), [qw( pending pending )], 'an unseen invoice takes no row';

    deliver( 'invoice.paid', invoice( 'in_two', 'pi_two' ) );
    deliver( 'invoice.voided', invoice( 'in_two', 'pi_two', status => 'void' ) );
    is_deeply statuses(), [qw( completed pending )], 'a completed row stays completed';
};

# Each month is its own invoice. A later month paying does not settle an
# earlier month's debt.
subtest 'month two failed then month three paid completes month three only' => sub {
    build_set();

    deliver( 'invoice.payment_failed', invoice( 'in_month_two', 'pi_month_two' ) );
    deliver( 'invoice.paid', invoice( 'in_month_three', 'pi_month_three',
        amount_due => 3334, amount_paid => 3334, status => 'paid' ) );

    is_deeply statuses(), [qw( failed completed )],
        "month three's row completes and month two stays failed";
};

# The seller can raise their own invoice against Registry's subscription on
# their account. Only what the schedule itself billed is an instalment.
subtest 'an invoice the schedule did not bill changes no instalment' => sub {
    build_set();
    @logs = ();

    for my $reason (qw( manual subscription_threshold )) {
        deliver( 'invoice.paid', invoice( "in_$reason", "pi_$reason",
            billing_reason => $reason, amount_paid => 3333, status => 'paid' ) );
        deliver( 'invoice.payment_failed', invoice( "in_${reason}_failed", "pi_${reason}_failed",
            billing_reason => $reason ) );
        is_deeply statuses(), [qw( pending pending )], "$reason marks no instalment";
    }

    # The seller sets billing_reason by how they raise the invoice; what they
    # put in it cannot forge a line in our log.
    deliver( 'invoice.paid', invoice( 'in_forged', 'pi_forged', billing_reason => "manual\nERROR forged" ) );
    my @warned = grep { $_->[0] eq 'warn' && $_->[1] =~ /billing_reason/ } @logs;
    is scalar @warned, 5, 'each dropped invoice is logged at warn';
    like $warned[0][1], qr/'manual'/, 'naming its billing_reason';
    like $warned[-1][1], qr/manual\\x\{a\}ERROR forged/, 'escaped';

    deliver( 'invoice.paid', invoice( 'in_create', 'pi_create', billing_reason => 'subscription_create' ) );
    is_deeply statuses(), [qw( completed pending )], 'subscription_create does';
};

# The schedule opens with a $0 period for the part paid at checkout, so its
# month-end anchor is the checkout date. That period's invoice is no instalment.
subtest 'the opening $0 invoice marks no instalment' => sub {
    build_set();
    for my $type (qw( invoice.paid invoice.payment_failed )) {
        deliver( $type, invoice( 'in_opening', undef, billing_reason => 'subscription_create',
            amount_due => 0, amount_paid => 0, status => 'paid' ) );
    }
    is_deeply statuses(), [qw( pending pending )], 'both parts still owed';
    is $A->{db}->query( q{SELECT count(*) FROM payments WHERE metadata->>'stripe_invoice_id' = 'in_opening'} )
        ->array->[0], 0, 'and no row is bound to it';
};

# The final instalment can be its own schedule phase (3333/3333/3334), and the
# invoice at a phase change may say subscription_update. It is still billed by
# the schedule, so it still settles the month it is for.
subtest 'a subscription_update invoice on the schedule completes the owed row' => sub {
    build_set();

    deliver( 'invoice.paid', invoice( 'in_update', 'pi_update', billing_reason => 'subscription_update' ) );
    is_deeply statuses(), [qw( completed pending )], 'the owed row is completed';
};

# Stripe's invoice at 2024-12-18.acacia: `subscription`, and no schedule field.
subtest 'an invoice naming only its subscription completes the earliest owed row' => sub {
    build_set();
    @lookups = ();

    deliver( 'invoice.paid', invoice( 'in_by_sub', 'pi_by_sub' ) );

    is_deeply statuses(), [qw( completed pending )],
        'the schedule the subscription names marks the earliest owed row';
    is_deeply \@lookups, [ [ $A->{account}, $SUB, { 'expand[]' => 'schedule' } ] ],
        "and the subscription was read, with its schedule, on the tenant's own account";
};

subtest 'a subscription with no schedule, or another schedule, changes nothing' => sub {
    build_set();

    for my $sub (qw( sub_studio_unscheduled sub_studio_own )) {
        Test::Registry::StripeWebhook::post_connect( $t, {
            type => 'invoice.paid', account => $A->{account},
            data => { object => invoice( "in_$sub", "pi_$sub", subscription => $sub ) } } )
            ->status_is(200)->content_is('OK');
        is_deeply statuses(), [qw( pending pending )], "$sub marks no instalment";
    }
};

# schedule_instalments_for records the rows only after Stripe made the
# schedule, and a past due date bills at once. That invoice is Registry's --
# the schedule names a paid child's entitlement still awaiting its schedule --
# so it is retried until the rows are there. A schedule naming no such
# entitlement is the studio's own, and is ignored as before.
subtest 'an invoice from a schedule not yet recorded asks for a retry' => sub {
    $A->{db}->delete( 'payments', { stripe_schedule_id => $SCHED } );
    my $c = checkout($A);
    local $SUBSCRIPTIONS{sub_early} = { id => 'sub_early',
        schedule => { id => $SCHED, metadata => { entitlement_id => $c->{entitlement}->id } } };
    local $SUBSCRIPTIONS{sub_forged} = { id => 'sub_forged',
        schedule => { id => 'sub_sched_forged', metadata => { entitlement_id => "not-a-uuid'" } } };

    my $event = { type => 'invoice.paid', account => $A->{account}, created => time,
        data => { object => invoice( 'in_early', 'pi_early', subscription => 'sub_early' ) } };
    Test::Registry::StripeWebhook::post_connect( $t, $event )->status_is(500);
    is $dao->db->select( 'registry.webhook_events', ['id'],
        { stripe_event_id => $event->{id} } )->rows, 0, 'the event is not claimed';

    # The job commits: the child's remaining parts are owed on the schedule.
    build_set( $A, $c );
    Test::Registry::StripeWebhook::post_connect( $t, $event )->status_is(200);
    is_deeply statuses(), [qw( completed pending )], "Stripe's retry marks the instalment";

    # A schedule naming an entitlement that has its schedule, or none, is not ours.
    local $SUBSCRIPTIONS{sub_early}{schedule}{id} = 'sub_sched_studio_twin';
    for my $sub (qw( sub_early sub_forged )) {
        Test::Registry::StripeWebhook::post_connect( $t, { type => 'invoice.paid', account => $A->{account},
            data => { object => invoice( "in_$sub", "pi_$sub", subscription => $sub ) } } )
            ->status_is(200)->content_is('OK');
    }
    is_deeply statuses(), [qw( completed pending )], 'and neither marks anything';
};

# A seller can name any entitlement whose schedule never comes (a job that
# failed for good): retrying that is only worth it while the job could still
# commit.
subtest 'an old not-yet-recorded schedule invoice answers 200 and warns' => sub {
    $A->{db}->delete( 'payments', { stripe_schedule_id => $SCHED } );
    my $c = checkout($A);
    local $SUBSCRIPTIONS{sub_stale} = { id => 'sub_stale',
        schedule => { id => $SCHED, metadata => { entitlement_id => $c->{entitlement}->id } } };

    @logs = ();
    my $event = { type => 'invoice.paid', account => $A->{account}, created => time - 25 * 3600,
        data => { object => invoice( 'in_stale', 'pi_stale', subscription => 'sub_stale' ) } };
    Test::Registry::StripeWebhook::post_connect( $t, $event )->status_is(200);
    ok( ( grep { $_->[0] eq 'warn' && $_->[1] =~ /\Q$event->{id}\E.*not recorded/ } @logs ),
        'and warns that the schedule was never recorded' );
};

subtest 'a not-yet-recorded schedule invoice naming an unpaid checkout answers 200' => sub {
    $A->{db}->delete( 'payments', { stripe_schedule_id => $SCHED } );
    my $c = checkout( $A, status => 'pending' );
    local $SUBSCRIPTIONS{sub_unpaid} = { id => 'sub_unpaid',
        schedule => { id => $SCHED, metadata => { entitlement_id => $c->{entitlement}->id } } };

    Test::Registry::StripeWebhook::post_connect( $t, { type => 'invoice.paid', account => $A->{account},
        created => time, data => { object => invoice( 'in_unpaid', 'pi_unpaid', subscription => 'sub_unpaid' ) } } )
        ->status_is(200)->content_is('OK');
};

# Unreadable now is not "not ours": the claim is not taken and Stripe retries.
subtest 'a subscription Stripe cannot return asks for a retry' => sub {
    build_set();

    my $event = { type => 'invoice.paid', account => $A->{account},
        data => { object => invoice( 'in_unreadable', 'pi_unreadable', subscription => 'sub_unreadable' ) } };
    Test::Registry::StripeWebhook::post_connect( $t, $event )->status_is(500);

    is_deeply statuses(), [qw( pending pending )], 'no instalment is marked';
    is $dao->db->select( 'registry.webhook_events', ['id'],
        { stripe_event_id => $event->{id} } )->rows, 0, 'and the event is not claimed';
};

# The studio's own invoicing on its own account is not Registry's to record, and
# reading it as tenant billing would move a tenant's status on a parent's card.
subtest 'unmatched connect invoice changes nothing and skips billing' => sub {
    build_set();

    for my $type (qw( invoice.paid invoice.payment_failed )) {
        my $event = { type => $type, account => $A->{account},
            data => { object => invoice( "in_studio_$type", "pi_studio_$type", subscription => 'sub_studio_own' ) } };
        Test::Registry::StripeWebhook::post_connect( $t, $event )
            ->status_is(200)->content_is('OK');

        is_deeply statuses(), [qw( pending pending )], "$type changes no instalment";
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

    deliver( 'invoice.paid', invoice( 'in_cross_tenant', 'pi_cross_tenant' ) );

    is_deeply statuses($B), [qw( pending pending )], 'the other tenant is untouched';
    is_deeply statuses($A), [], 'and the tenant the account names has nothing to mark';
};

# Stripe does not promise delivery order. A failed attempt reported after the
# retry that paid is history, not news.
subtest 'failed after paid never reverts a completed instalment' => sub {
    build_set();

    deliver( 'invoice.paid', invoice( 'in_two', 'pi_two_late' ) );
    deliver( 'invoice.payment_failed', invoice( 'in_two', 'pi_two_late' ) );

    is_deeply statuses(), [qw( completed pending )],
        'the paid instalment stays completed and the next is not failed';
};

# Money already on its way back is past every invoice event: a late or
# redelivered paid, failed or voided invoice must not walk the row back.
subtest 'a refunded or refund_pending instalment is not moved by an invoice event' => sub {
    my @ids = build_set();
    deliver( 'invoice.paid', invoice( 'in_two', 'pi_two' ) );
    deliver( 'invoice.paid', invoice( 'in_three', 'pi_three' ) );

    for my $type (qw( invoice.paid invoice.payment_failed invoice.voided )) {
        $A->{db}->query( q{UPDATE payments SET status = 'refunded', refunded_cents = amount_cents WHERE id = ?},
            $ids[0] );
        $A->{db}->query( q{UPDATE payments SET status = 'refund_pending', refund_owed_cents = amount_cents WHERE id = ?},
            $ids[1] );
        deliver( $type, invoice( $_, "pi_$_" ) ) for qw( in_two in_three );
        is_deeply statuses(), [qw( refunded refund_pending )], "$type moves neither row";
    }
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
        data => { object => invoice( 'in_platform_inst', 'pi_platform_inst' ) } },
        path => '/webhooks/stripe', secret => $ENV{STRIPE_WEBHOOK_SECRET} )->status_is(200);

    is_deeply statuses($reg), [qw( pending pending )], 'no registry instalment is marked';
    is_deeply statuses(),     [qw( pending pending )], 'nor any tenant instalment';
    $dao->db->delete( 'payments', { stripe_schedule_id => $SCHED } );
};

# The seller owns the account, so they own every subscription's metadata on it
# and can write our schedule id there. Only an id Stripe sets ties an invoice
# to the schedule Registry stored.
subtest 'seller metadata naming a schedule marks nothing' => sub {
    build_set();

    deliver( 'invoice.paid', {
        subscription_details => { metadata => { subscription => $SUB } },
        payment_intent       => 'pi_seller_own' } );

    is_deeply statuses(), [qw( pending pending )], 'no instalment is marked paid';
};

$t_db->cleanup_test_database;
