#!/usr/bin/env perl
# ABOUTME: The second half of a change: once the fee is paid, CompleteChange moves the entitlement onto the held target.
# ABOUTME: Settled by payment_intent.succeeded on the Connect endpoint, whose job drives the run with nobody present.
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
use Registry::DAO::Entitlement;
use Registry::PriceOps::Hold;

local $ENV{STRIPE_WEBHOOK_SECRET}         = 'whsec_local_change_fee';
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_local_change_fee_connect';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub ( $c, $tenant = undef ) {
    defined $tenant ? Registry::DAO->new( url => $test_db->uri, schema => $tenant ) : $dao } );
my $minion = $t->app->minion;

# A seller with a Stripe account and platform terms, so a fee can be charged.
my $SLUG    = "ccm_$$";
my $ACCOUNT = "acct_ccm_$$";
my $admin   = Registry::DAO::User->create( $db, {
    username => "ccm_admin_$$", email => "ccm_admin_$$\@test.example",
    name => 'CCM Admin', user_type => 'admin' } );
Registry::DAO::Tenant->provision( $db, {
    name => "CCM $$", slug => $SLUG, users => [$admin],
    stripe_connect_account_id => $ACCOUNT, stripe_charges_enabled => 1, stripe_details_submitted => 1 } );
give_tenant_terms( $db, $SLUG, { rate => '0.025' } );
my $studio = $dao->connect_schema($SLUG)->db;

my %WINDOW = ( kind => 'window', window_hours => 48, fee_cents => 1000, targets => 'same_offer' );
my $made   = 0;

sub person () {
    return $studio->insert( 'users', { username => "ccm-p-$$-" . ++$made }, { returning => 'id' } )->hash->{id};
}

# A class whose occurrences start $hours from now, each with four seats, and
# a published class offer version covering them with change policy $change
# and end-of-occurrence expiry. Returns the version and the resources.
sub occurrences ( $change, @hours ) {
    my $class = $studio->insert( 'projects', { name => 'Class ' . ++$made, slug => "class-$made" },
        { returning => 'id' } )->hash->{id};
    my @resources = map {
        my $room = $studio->insert( 'locations', { name => 'Room ' . ++$made, slug => "room-$made" },
            { returning => 'id' } )->hash->{id};
        my $event = $studio->insert( 'events', {
            project_id => $class, location_id => $room, teacher_id => person(),
            time       => \"now() + interval '$_ hours'", duration => 90, capacity => 4,
        }, { returning => 'id' } )->hash->{id};
        Registry::DAO::Resource->for_occurrence( $studio, $event );
    } @hours;
    my $version = Registry::DAO::Offer->create( $studio, { name => 'Wheel class ' . $made } )
        ->draft( $studio, offer_terms( undef, class_project_id => $class, policies => {
            refund => { kind => 'none' }, change => $change, expiry => { kind => 'end_of_occurrence' } } ) )
        ->publish($studio);
    return ( $version, @resources );
}

# An entitlement under $version holding $units seats of $resource, in effect
# until that occurrence ends, as end-of-occurrence expiry stamps it.
sub booking ( $version, $resource, $units = 1 ) {
    my ( undef, $ends ) = $resource->occurrence_window($studio);
    return Registry::DAO::Entitlement->grant( $studio, {
        holder_user_id   => person(),
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
        starts_at        => '2020-01-01T00:00:00Z',
        ends_at          => $ends,
        resource_id      => $resource->id,
        units            => $units,
    } );
}

my $workflow = Registry::DAO::Workflow->create( $studio,
    { slug => 'change-fee-test', name => 'Change fee test', description => 'change completion under test' } );
$workflow->add_step( $studio, { slug => $_->[0], class => $_->[1] } ) for
    [ 'choose-target' => 'Registry::DAO::WorkflowSteps::ChooseChangeTarget' ],
    [ 'hold-target'   => 'Registry::DAO::WorkflowSteps::HoldChangeTarget' ],
    [ 'pay'           => 'Registry::DAO::WorkflowSteps::OneTimePayment' ],
    [ 'complete'      => 'Registry::DAO::WorkflowSteps::CompleteChange' ];

sub step ($slug) { $workflow->get_step( $studio, { slug => $slug } ) }

sub reload ($run) { Registry::DAO::WorkflowRun->find( $studio, { id => $run->id } ) }

# A run that chose to change $entitlement and holds $target for it.
sub held_run ( $entitlement, $target ) {
    my $run = $workflow->new_run( $studio, {} );
    $run->update_data( $studio, { user_id => $entitlement->holder_user_id, __tenant_slug => $SLUG } );
    $run->process( $studio, step('choose-target'), { entitlement_id => $entitlement->id } );
    my $held = $run->process( $studio, step('hold-target'), { target_occurrence_id => $target->id } );
    die 'hold refused: ' . explain $held->{errors} if $held->{errors};
    return reload($run);
}

# The fee payment this run started, with the intent Stripe answered recorded,
# named on the run as OneTimePayment names it.
sub fee_payment ( $run, $amount = $run->data->{change_hold}{fee_cents} ) {
    my $payment = Registry::DAO::Payment->create( $studio, {
        user_id          => $run->data->{user_id},
        amount_cents     => $amount,
        offer_version_id => $run->data->{change_hold}{offer_version_id},
        metadata         => { workflow_id => $workflow->id, workflow_run_id => $run->id,
                              tenant_slug => $SLUG, payment_plan_id => 'pay', description => 'Change fee' },
    } );
    $payment->_record_intent( $studio, { id => 'pi_ccm_' . $payment->id, client_secret => 'x_secret' } );
    $run->update_data( $studio, { owed_payment_id => $payment->id } );
    return $payment;
}

# payment_intent.succeeded on the Connect endpoint for $payment, as Stripe sends it.
sub succeeded ($payment) {
    return Test::Registry::StripeWebhook::post_connect( $t, {
        type    => 'payment_intent.succeeded',
        account => $ACCOUNT,
        data    => { object => {
            id       => $payment->stripe_payment_intent_id,
            amount   => $payment->amount_cents,
            metadata => { payment_id => $payment->id, tenant_slug => $SLUG },
        } },
    } );
}

# Has Minion's worker perform every queued job.
sub drive () { $minion->perform_jobs }

# The run's hold lapses, as the clock would make it.
sub lapse ($run) {
    $studio->query( q{UPDATE holds SET expires_at = clock_timestamp() - interval '1 second'
                       WHERE workflow_run_id = ?}, $run->id );
}

sub hold_is_live ($run) {
    my $live = Registry::PriceOps::Hold->live_sql('holds');
    $studio->query( "SELECT $live FROM holds WHERE id = ?", reload($run)->data->{change_hold}{hold_id} )
        ->array->[0];
}

sub payments_of ($run) {
    $studio->query( q{SELECT * FROM payments WHERE metadata->>'workflow_run_id' = ?}, $run->id )
        ->hashes->to_array;
}

sub hold_state ($run) {
    $studio->select( 'holds', 'state', { id => reload($run)->data->{change_hold}{hold_id} } )->array->[0];
}

subtest 'paid change moves entitlement once' => sub {
    my ( $version, $from, $to ) = occurrences( \%WINDOW, 72, 96 );
    my $e   = booking( $version, $from, 2 );
    my $run = held_run( $e, $to );

    is_deeply { reload($run)->data->{owed_payment}->%{qw( amount_cents offer_version_id payment_plan hold_id )} }, {
        amount_cents     => 1000,
        offer_version_id => $version->id,
        payment_plan     => 'pay',
        hold_id          => reload($run)->data->{change_hold}{hold_id},
    }, 'the hold step owes the stamped fee, under the entitlement\'s plan, for the hold';

    succeeded( fee_payment($run) )->status_is(200);
    drive();

    is_deeply $e->units( $studio, $to->id ), [ 1, 2 ], 'the entitlement holds the target\'s seats';
    is_deeply $e->units( $studio, $from->id ), [], 'and none of the old occurrence\'s';
    is $from->free_units($studio), 4, 'whose seats are free again';
    is $to->free_units($studio), 2, 'the target has its two other seats free';
    is hold_state($run), 'converted', 'the hold is converted';
    ok reload($run)->completed($studio), 'the run is complete';

    my ( undef, $from_ends ) = $from->occurrence_window($studio);
    my ( undef, $to_ends )   = $to->occurrence_window($studio);
    ok Registry::DAO::Entitlement->in_effect_at( $studio,
        $studio->query( q{SELECT ?::timestamptz + interval '1 hour'}, $from_ends )->array->[0],
        { id => $e->id } ), 'it stays in effect past the old occurrence\'s end';
    is $studio->query( 'SELECT upper(in_effect) = ?::timestamptz FROM entitlements WHERE id = ?',
        $to_ends, $e->id )->array->[0], 1, 'until the target occurrence ends';
    is $studio->select( 'entitlements', 'count(*)', { offer_version_id => $version->id } )->array->[0], 1,
        'no second entitlement is made';

    # The person's return arrives after the driver, and Stripe redelivers.
    my $again = $run->process( $studio, step('complete'), {} );
    ok !$again->{errors}, 'completing again is not refused' or diag explain $again;
    succeeded( Registry::DAO::Payment->find( $studio, { id => reload($run)->data->{owed_payment_id} } ) )
        ->status_is(200);
    drive();
    is_deeply $e->units( $studio, $to->id ), [ 1, 2 ], 'the entitlement still holds the same two target seats';
    is $to->free_units($studio), 2, 'and no more';
    is_deeply [ map { $_->{state} } $studio->select( 'holds', 'state', { workflow_run_id => $run->id } )->hashes->@* ],
        ['converted'], 'the run has its one converted hold';
};

subtest 'zero fee change completes without payment' => sub {
    my ( $version, $from, $to ) = occurrences( { %WINDOW, fee_cents => 0 }, 72, 96 );
    my $e   = booking( $version, $from );
    my $run = held_run( $e, $to );
    ok !defined reload($run)->data->{owed_payment}, 'nothing is owed';
    my $done = $run->process( $studio, step('complete'), {} );
    ok !$done->{errors}, 'the change completes' or diag explain $done;
    is_deeply $e->units( $studio, $to->id ), [1], 'the entitlement holds the target seat';
    is $from->free_units($studio), 4, 'and the old one is free';
    is hold_state($run), 'converted', 'the hold is converted';
    is_deeply payments_of($run), [], 'with no payment';
};

subtest 'failed charge or lapsed hold releases hold' => sub {
    my ( $version, $from, $to ) = occurrences( \%WINDOW, 72, 96 );

    my $e   = booking( $version, $from );
    my $run = held_run( $e, $to );
    my $payment = fee_payment($run);
    $payment->_record_intent_failure_write( $studio, 'Your card was declined.' );    # as a decline records it
    ok $run->process( $studio, step('complete'), {} )->{errors}, 'a failed charge does not complete the change';
    lapse($run);
    ok !hold_is_live($run), 'its hold lapses, which releases it';
    is $to->free_units($studio), 4, 'so the target keeps every seat';
    is_deeply $e->units( $studio, $from->id ), [1], 'and the entitlement stays where it was';

    $e   = booking( $version, $from );
    $run = held_run( $e, $to );
    lapse($run);
    my $paid = $run->process( $studio, step('pay'), {} );
    like "@{ $paid->{errors} // [] }", qr/lapsed/, 'a hold that lapsed before the charge refuses the charge';
    is_deeply payments_of($run), [], 'and no payment is started';
    is hold_state($run), 'released', 'the hold is released';
    is $to->free_units($studio), 4, 'the target keeps every seat';
    is scalar $e->units( $studio, $from->id )->@*, 1, 'and the entitlement stays where it was';
};

# The studio's admin, told of a paid change it must settle.
my $studio_admin = $studio->insert( 'users', { username => "ccm-admin-$$", user_type => 'admin' },
    { returning => 'id' } )->hash->{id};

sub admin_alerts ($run) {
    $studio->query( q{SELECT count(*) FROM notifications WHERE user_id = ? AND metadata->>'workflow_run_id' = ?},
        $studio_admin, $run->id )->array->[0];
}

sub hold_row ($run) {
    $studio->query( q{SELECT *, expires_at - placed_at AS length,
                             expires_at = placed_at + 2 * lifetime AS at_bound FROM holds WHERE id = ?},
        reload($run)->data->{change_hold}{hold_id} )->hash;
}

subtest 'charge start extends live hold' => sub {
    my ( $version, $from, $to ) = occurrences( \%WINDOW, 72, 96 );
    my $run    = held_run( booking( $version, $from ), $to );
    my $before = hold_row($run);
    ok !step('pay')->hold_for_charge( $studio, $run ), 'a live hold lets the charge start';
    my $after = hold_row($run);
    is $studio->query( 'SELECT ?::timestamptz = ?::timestamptz + ?::interval',
        $after->{expires_at}, $before->{expires_at}, $before->{length} )->array->[0], 1,
        'and is extended by its own length when the charge starts';

    fee_payment($run);
    ok !step('pay')->hold_for_charge( $studio, reload($run) ), 'a resubmit once the charge started is let through';
    is hold_row($run)->{expires_at}, $after->{expires_at}, 'without extending the hold again';
};

subtest 'extension bounded however often the charge starts' => sub {
    my ( $version, $from, $to ) = occurrences( \%WINDOW, 72, 96 );
    my $run = held_run( booking( $version, $from ), $to );
    step('pay')->hold_for_charge( $studio, $run );
    my $once = hold_row($run);
    ok $once->{at_bound}, 'the first charge start extends the hold to twice its lifetime';
    # A second request loaded the run before the first wrote owed_payment_id.
    step('pay')->hold_for_charge( $studio, $run ) for 1 .. 3;
    is hold_row($run)->{expires_at}, $once->{expires_at}, 'a second start does not extend it again';

    # The seller cannot take charges, so owed_payment refuses every post and
    # no payment is ever named on the run.
    $db->query( 'UPDATE registry.tenants SET stripe_charges_enabled = false WHERE slug = ?', $SLUG );
    my $refused = held_run( booking( $version, $from ), $to );
    my @warned;
    my @errors = do {
        local $SIG{__WARN__} = sub { push @warned, @_ };
        map { reload($refused)->process( $studio, step('pay'), {} )->{errors} } 1 .. 4;
    };
    is scalar( grep { /\Q$SLUG\E' is not Stripe Connect ready/ } @warned ), 4,
        'each refused post tells the operator which tenant';
    $db->query( 'UPDATE registry.tenants SET stripe_charges_enabled = true WHERE slug = ?', $SLUG );
    ok !grep( { !$_ } @errors ), 'every post is refused';
    ok !defined reload($refused)->data->{owed_payment_id}, 'and starts no payment';
    ok hold_row($refused)->{at_bound}, 'the hold never runs past twice its lifetime';
};

subtest 'succeeded charge after lapse retakes seat' => sub {
    my ( $version, $from, $to ) = occurrences( \%WINDOW, 72, 96 );
    my $e     = booking( $version, $from, 2 );
    my $run   = held_run( $e, $to );
    my $first = reload($run)->data->{change_hold}{hold_id};
    my $payment = fee_payment($run);
    lapse($run);
    succeeded($payment)->status_is(200);
    drive();
    is_deeply $e->units( $studio, $to->id ), [ 1, 2 ], 'the seats are taken again and the entitlement moves';
    is $from->free_units($studio), 4, 'freeing the old ones';
    is $studio->select( 'holds', 'state', { id => $first } )->array->[0], 'released', 'the lapsed hold is released';
    is hold_state($run), 'converted', 'and the run names the converted one';
    ok reload($run)->completed($studio), 'the run is complete';
};

subtest 'succeeded charge with full target needs admin' => sub {
    my ( $version, $from, $to ) = occurrences( \%WINDOW, 72, 96 );
    my $e       = booking( $version, $from );
    my $run     = held_run( $e, $to );
    my $payment = fee_payment($run);
    lapse($run);
    booking( $version, $to, 4 );    # the target sells out while the hold is lapsed
    succeeded($payment)->status_is(200);
    drive();

    is_deeply $e->units( $studio, $from->id ), [1], 'the entitlement stays on its old seat';
    is_deeply $e->units( $studio, $to->id ), [], 'and has none of the target';
    my $data = reload($run)->data;
    is $data->{change_needs_admin}{payment_id}, $payment->id, 'the run records the paid change as needing an admin';
    like $data->{__driver}{error}, qr/admin/, 'the driver records why it stopped';
    is admin_alerts($run), 1, 'and one alert goes to the studio admin';
    ok !reload($run)->completed($studio), 'the run is not complete';
    is Registry::DAO::Payment->find( $studio, { id => $payment->id } )->status, 'completed',
        'and the fee is kept, not refunded';

    my $id = $minion->enqueue( continue_workflow_run => [ { tenant => $SLUG, run_id => $run->id } ],
        { attempts => 1 } );
    $minion->perform_jobs( { id => $id } );
    is reload($run)->data->{__driver}{state}, 'halted', 'its last attempt halts the run for an admin';
};

subtest 'paid change of ended entitlement needs admin' => sub {
    my ( $version, $from, $to ) = occurrences( \%WINDOW, 72, 96 );
    my $e       = booking( $version, $from );
    my $run     = held_run( $e, $to );
    my $payment = fee_payment($run);
    $e->end( $studio, 'expired', 'ended before the change completed' );
    succeeded($payment)->status_is(200);
    drive();

    is_deeply $e->units( $studio, $to->id ), [], 'the ended entitlement is not moved';
    is hold_state($run), 'held', 'the hold is not converted';
    is reload($run)->data->{change_needs_admin}{payment_id}, $payment->id,
        'the run records the paid change as needing an admin';
    is admin_alerts($run), 1, 'the studio admin is alerted';
    is Registry::DAO::Payment->find( $studio, { id => $payment->id } )->status, 'completed',
        'and the fee is kept, not refunded';
    is $minion->jobs( { tasks => [ grep { /refund/ } keys $minion->tasks->%* ] } )->total, 0,
        'with no refund job queued';

    my $id = $minion->enqueue( continue_workflow_run => [ { tenant => $SLUG, run_id => $run->id } ],
        { attempts => 1 } );
    $minion->perform_jobs( { id => $id } );
    is reload($run)->data->{__driver}{state}, 'halted', 'its last attempt halts the run for an admin';
};

# The fee payment, completed as the Connect webhook completes it.
sub completed ($payment) {
    $payment->mark_completed( $studio, $payment->stripe_payment_intent_id ) or die 'not completed';
    return $payment;
}

# Nothing moved for $e: still on $from's seat, none of $to's, $run's hold held.
sub unmoved ( $e, $from, $to, $run, $what ) {
    is scalar $e->units( $studio, $from->id )->@*, 1, "$what: the entitlement keeps its old seat";
    is_deeply $e->units( $studio, $to->id ), [], "$what: and has none of the target";
    is hold_state($run), 'held', "$what: the hold is still held, not converted";
}

subtest 'pending payment does not move' => sub {
    my ( $version, $from, $to ) = occurrences( \%WINDOW, 72, 96 );
    my $e   = booking( $version, $from );
    my $run = held_run( $e, $to );
    fee_payment($run);
    ok $run->process( $studio, step('complete'), {} )->{errors}, 'completing with the fee still pending is refused';
    unmoved( $e, $from, $to, $run, 'pending' );
};

subtest 'foreign or wrong amount payment does not move' => sub {
    my ( $version, $from, $to ) = occurrences( \%WINDOW, 72, 96 );
    my $other = held_run( booking( $version, $from ), $to );
    my $theirs = completed( fee_payment($other) );

    my $e   = booking( $version, $from );
    my $run = held_run( $e, $to );
    $run->update_data( $studio, { owed_payment_id => $theirs->id } );
    ok $run->process( $studio, step('complete'), {} )->{errors}, "another run's paid fee is refused";
    unmoved( $e, $from, $to, $run, 'foreign' );

    completed( fee_payment( $run, 999 ) );
    ok $run->process( $studio, step('complete'), {} )->{errors}, 'a paid amount other than the stamped fee is refused';
    unmoved( $e, $from, $to, $run, 'wrong amount' );
};

subtest 'partial move failure rolls back' => sub {
    my ( $version, $from, $to ) = occurrences( \%WINDOW, 72, 96 );
    my $e   = booking( $version, $from );
    my $run = held_run( $e, $to );
    completed( fee_payment($run) );
    # The period move is the last write of the move: fail it, after the seats moved.
    $studio->query( q{CREATE FUNCTION refuse_period() RETURNS trigger LANGUAGE plpgsql
                      AS $$ BEGIN RAISE EXCEPTION 'period move refused'; END $$} );
    $studio->query( q{CREATE TRIGGER refuse_period BEFORE UPDATE OF in_effect ON entitlements
                      FOR EACH ROW EXECUTE FUNCTION refuse_period()} );
    my $died = !eval { $run->process( $studio, step('complete'), {} ); 1 };
    my $error = $@;
    $studio->query('DROP TRIGGER refuse_period ON entitlements');
    $studio->query('DROP FUNCTION refuse_period()');
    ok $died, 'the move dies' and like $error, qr/period move refused/, 'where the period moves';
    unmoved( $e, $from, $to, $run, 'rolled back' );
    is $to->free_units($studio), 3, 'and the target has only the held seat taken';
};

subtest 'client payment status ignored' => sub {
    my ( $version, $from, $to ) = occurrences( \%WINDOW, 72, 96 );
    my $other  = held_run( booking( $version, $from ), $to );
    my $theirs = completed( fee_payment($other) );
    my $e      = booking( $version, $from );
    my $run    = held_run( $e, $to );
    fee_payment($run);
    my $out = $run->process( $studio, step('complete'), {
        payment_status => 'completed', status => 'completed', paid => 1,
        payment_id     => $theirs->id, owed_payment_id => $theirs->id, payment_intent_id => 'pi_forged',
        change_hold    => { fee_cents => 0, hold_id => reload($run)->data->{change_hold}{hold_id} },
    } );
    ok $out->{errors}, 'a posted payment status or id does not complete the change';
    unmoved( $e, $from, $to, $run, 'posted status' );
};

subtest 'hold refused once charge started' => sub {
    my ( $version, $from, $to, $later ) = occurrences( \%WINDOW, 72, 96, 120 );
    my $e    = booking( $version, $from );
    my $run  = held_run( $e, $to );
    my $hold = reload($run)->data->{change_hold}{hold_id};
    fee_payment($run);
    my $again = $run->process( $studio, step('hold-target'), { target_occurrence_id => $later->id } );
    ok $again->{errors}, 'holding again once the fee charge started is refused';
    is reload($run)->data->{change_hold}{hold_id}, $hold, 'the run keeps the hold the charge is for';
    is $studio->select( 'holds', 'state', { id => $hold } )->array->[0], 'held', 'which stays held';
    is $later->free_units($studio), 4, 'and no other seat is held';
};

subtest 'no path refunds change fee' => sub {
    my ( $version, $from, $to ) = occurrences( \%WINDOW, 72, 96 );
    my @runs;

    my $failed = held_run( booking( $version, $from ), $to );
    fee_payment($failed)->_record_intent_failure_write( $studio, 'Your card was declined.' );
    lapse($failed);
    $failed->process( $studio, step('complete'), {} );
    push @runs, $failed;

    my $early = held_run( booking( $version, $from ), $to );
    lapse($early);
    $early->process( $studio, step('pay'), {} );
    push @runs, $early;

    my $full = held_run( booking( $version, $from ), $to );
    my $paid = fee_payment($full);
    lapse($full);
    booking( $version, $to, $to->free_units($studio) );
    succeeded($paid)->status_is(200);
    drive();
    push @runs, $full;

    my @payments = map { payments_of($_)->@* } @runs;
    ok !grep( { $_->{status} =~ /refund/ } @payments ), 'no fee payment is refunded or owed a refund'
        or diag explain [ map { $_->{status} } @payments ];
    is_deeply [ map { $_->{status} } grep { $_->{id} eq $paid->id } @payments ], ['completed'],
        'the paid fee with no seat left stays completed';
    my $refunds = $minion->jobs( { tasks => [ grep { /refund/ } keys $minion->tasks->%* ] } )->total;
    is $refunds, 0, 'and no refund job is queued';
};

done_testing;
