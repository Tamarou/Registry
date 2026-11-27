# ABOUTME: The instalment_reconcile job settles paid instalment invoices whose webhook was dropped, run by Minion's own worker.
# ABOUTME: It marks a child's earliest owed entitlement row (or the row the invoice is bound to) and records its fee once.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use experimental qw(signatures);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::InstalmentCheckout qw( instalment_checkout );
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::Service::Stripe;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_instalment_reconcile';

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;

my $slug    = "ir_tenant_$$";
my $account = "acct_ir_$$";
my $admin   = Registry::DAO::User->create( $db, {
    username => "ir_admin_$$", email => "ir_admin_$$\@test.example",
    name => 'IR Admin', user_type => 'admin' } );
Registry::DAO::Tenant->provision( $db, {
    name => "IR Tenant $$", slug => $slug, users => [$admin],
    stripe_connect_account_id => $account,
    stripe_charges_enabled => 1, stripe_details_submitted => 1 } );
my $tdb = Registry::DAO->new( url => $test_db->uri, schema => $slug )->db;

my $t      = Test::Registry::Mojo->new('Registry');
my $minion = $t->app->minion;

my @logs;
$t->app->log->unsubscribe('message');
$t->app->log->level('info');
$t->app->log->on( message => sub ( $log, $level, @lines ) { push @logs, [ $level, "@lines" ] } );

# A child's set of three as schedule_instalments_for leaves it: part one paid
# by the checkout charge, parts two and three owed on the child's entitlement
# and schedule $sched. %bound binds a row (by seq) to an invoice id. Returns
# the entitlement.
sub build_set ( $sched, %bound ) {
    my $c = instalment_checkout($tdb);
    for my $i ( 2 .. 3 ) {
        $tdb->insert( 'payments', {
            user_id            => $c->{parent},
            amount_cents       => 3333,
            currency           => 'USD',
            status             => 'pending',
            instalment_seq     => $i,
            instalment_count   => 3,
            stripe_schedule_id => $sched,
            entitlement_id     => $c->{entitlement}->id,
            metadata           => { -json => {
                stripe_account_id => $account,
                instalment_of     => $c->{payment}->id,
                ( $bound{$i} ? ( stripe_invoice_id => $bound{$i} ) : () ),
            } },
        } );
    }
    return $c->{entitlement};
}

sub paid_invoice ( $id, $created ) {
    return { id => $id, object => 'invoice', status => 'paid', created => $created,
        billing_reason => 'subscription_cycle', payment_intent => "pi_$id",
        application_fee_amount => 83 };
}

# Stripe's side: each schedule names its subscription, and each subscription
# lists its paid invoices. Runs the job to its end and returns what was asked.
sub run_job ( $schedules, $invoices ) {
    my @asked;
    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_subscription_schedule = sub ( $s, $id ) {
        push @asked, [ schedule => $s->stripe_account, $id ];
        return { id => $id, subscription => $schedules->{$id} };
    };
    local *Registry::Service::Stripe::list_invoices = sub ( $s, $p ) {
        push @asked, [ invoices => $s->stripe_account, $p ];
        return { data => $invoices->{ $p->{subscription} } // [] };
    };
    my $id = $minion->enqueue('instalment_reconcile');
    $minion->perform_jobs_in_foreground( { id => $id } );
    is $minion->job($id)->info->{state}, 'finished', 'the job finished';
    return \@asked;
}

# Instalments two and three, in that order.
sub rows ($sched) {
    $tdb->query( q{
        SELECT instalment_seq, status, stripe_payment_intent_id, platform_fee_cents,
               metadata->>'stripe_invoice_id' AS invoice, entitlement_id
          FROM payments WHERE stripe_schedule_id = ? ORDER BY instalment_seq
    }, $sched )->hashes->to_array;
}

subtest 'the reconcile job settles a paid invoice on an entitlement row' => sub {
    my $e = build_set('sub_sched_ir_dropped');
    my $asked = run_job( { sub_sched_ir_dropped => 'sub_ir_dropped' },
        { sub_ir_dropped => [ paid_invoice( 'in_ir_dropped', 1_700_000_000 ) ] } );

    is_deeply [ grep { $_->[0] eq 'invoices' && $_->[2]{subscription} eq 'sub_ir_dropped' } @$asked ],
        [ [ invoices => $account, { subscription => 'sub_ir_dropped', status => 'paid', limit => 100 } ] ],
        "the subscription's paid invoices were listed on the tenant's account";
    my $rows = rows('sub_sched_ir_dropped');
    is $rows->[0]{entitlement_id}, $e->id, "the row is the child's entitlement's";
    is $rows->[0]{status},  'completed',     'instalment two is paid';
    is $rows->[0]{invoice}, 'in_ir_dropped', 'bound to the invoice';
    is $rows->[0]{stripe_payment_intent_id}, 'pi_in_ir_dropped', 'with its payment intent';
    is $rows->[0]{platform_fee_cents}, 83, 'and its fee recorded';
    is $rows->[1]{status}, 'pending', 'instalment three is still owed';
    is $e->paid_cents($tdb), $e->payment_share_cents + 3333, 'and the entitlement has paid its share and part two';

    my $before = rows('sub_sched_ir_dropped');
    run_job( { sub_sched_ir_dropped => 'sub_ir_dropped' },
        { sub_ir_dropped => [ paid_invoice( 'in_ir_dropped', 1_700_000_000 ) ] } );
    is_deeply rows('sub_sched_ir_dropped'), $before, 'a second run changes nothing';
};

# A row is bound before payment by invoice.payment_failed: pending with no
# intent, failed with one. If the retry's invoice.paid is then lost, the job
# settles that row.
for my $status (qw(pending failed)) {
    subtest "a bound $status row whose paid event was dropped ends completed with its fee" => sub {
        my $sched = "sub_sched_ir_bound_$status";
        build_set( $sched, 2 => "in_ir_bound_$status" );
        $tdb->query( q{UPDATE payments SET status = ? WHERE stripe_schedule_id = ? AND instalment_seq = 2},
            $status, $sched );
        run_job( { $sched => "sub_ir_bound_$status" },
            { "sub_ir_bound_$status" => [ paid_invoice( "in_ir_bound_$status", 1_700_000_000 ) ] } );
        my $rows = rows($sched);
        is $rows->[0]{status}, 'completed', 'instalment two is paid';
        is $rows->[0]{stripe_payment_intent_id}, "pi_in_ir_bound_$status", 'with its payment intent';
        is $rows->[0]{platform_fee_cents}, 83, 'and its fee recorded';
        is $rows->[1]{status}, 'pending', 'instalment three is still owed';
    };
}

subtest 'a bound completed row is left as it is, with no second fee' => sub {
    build_set( 'sub_sched_ir_bound_done', 2 => 'in_ir_bound_done' );
    $tdb->query( q{UPDATE payments SET status = 'completed', platform_fee_cents = 50
                   WHERE stripe_schedule_id = ? AND instalment_seq = 2}, 'sub_sched_ir_bound_done' );
    my $before = rows('sub_sched_ir_bound_done');
    run_job( { sub_sched_ir_bound_done => 'sub_ir_bound_done' },
        { sub_ir_bound_done => [ paid_invoice( 'in_ir_bound_done', 1_700_000_000 ) ] } );
    is_deeply rows('sub_sched_ir_bound_done'), $before, 'no row changed';
};

subtest 'the opening $0 invoice is neither settled nor flagged' => sub {
    build_set('sub_sched_ir_opening');
    my $before = rows('sub_sched_ir_opening');
    @logs = ();
    run_job( { sub_sched_ir_opening => 'sub_ir_opening' },
        { sub_ir_opening => [ { %{ paid_invoice( 'in_ir_opening', 1_600_000_000 ) },
            billing_reason => 'subscription_create', amount_due => 0, amount_paid => 0 } ] } );
    is_deeply rows('sub_sched_ir_opening'), $before, 'no row changed';
    is scalar( grep { $_->[0] eq 'error' && $_->[1] =~ /sub_sched_ir_opening/ } @logs ), 0,
        'and nothing is flagged';
};

subtest 'a paid invoice that matches no owed row is flagged for ops' => sub {
    build_set( 'sub_sched_ir_full', 2 => 'in_ir_two', 3 => 'in_ir_three' );
    # Two paid, three's card declined: still owed, but its own month, so no
    # other invoice may take it.
    $tdb->query( q{UPDATE payments SET status = CASE instalment_seq WHEN 3 THEN 'failed'
                   ELSE 'completed' END WHERE stripe_schedule_id = ?}, 'sub_sched_ir_full' );
    @logs = ();
    run_job( { sub_sched_ir_full => 'sub_ir_full' },
        { sub_ir_full => [ paid_invoice( "in_ir_extra\n", 1_700_000_000 ) ] } );
    my @flags = grep { $_->[0] eq 'error' && $_->[1] =~ /sub_sched_ir_full/ } @logs;
    is scalar @flags, 1, 'once, at error';
    like $flags[0][1] // '', qr/\Q$slug\E.*in_ir_extra\\x\{a\}/, 'naming the tenant and the escaped invoice';
};

done_testing;
