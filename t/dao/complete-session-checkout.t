#!/usr/bin/env perl
# ABOUTME: Completing a paid session cart: each child holds an entitlement paid by the parent, sharing the one charge.
# ABOUTME: Driven from a stored payment_intent.succeeded; a lost seat refunds its line alone, and an instalment child is scheduled.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( days_from_now );
use Test::Registry::PricingProbe qw( state_platform_terms );
use Test::Registry::Sessions qw( make_session session_offer held_cart );
use Test::Registry::Offers qw( instalment_plan );
use Test::Registry::SessionCheckout qw( started_charge post_succeeded drive );
use Test::Registry::Async;
use Mojo::Promise;
use Registry::DAO::Entitlement;
use Registry::DAO::FamilyMember;
use Registry::DAO::Payment;
use Registry::DAO::WorkflowRun;
use Registry::PriceOps::Instalments ();
use Registry::Service::Stripe;
use Registry::Terms;

local $ENV{STRIPE_SECRET_KEY}             = 'sk_test_placeholder_complete_checkout';
local $ENV{STRIPE_WEBHOOK_SECRET}         = 'whsec_complete_checkout';
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_complete_checkout_connect';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# registry sells its own sessions here, on a ready account under Solo's 2.5%.
my $seller = Test::Registry::Fixtures::platform_seller($db);
$db->query( q{UPDATE registry.tenants SET stripe_charges_enabled = TRUE, stripe_details_submitted = TRUE
               WHERE slug = ?}, $seller );
state_platform_terms( $db, $seller, { rate => '0.025' } );
my $account = 'acct_platform_test';

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub ( $c, $tenant = undef ) { $dao } );
my $minion = $t->app->minion;

my $admin  = Test::Registry::Fixtures::create_user( $db, { username => 'csc_admin', name => 'CSC Admin',
    email => 'csc_admin@test.example', user_type => 'admin' } );
my $parent = Test::Registry::Fixtures::create_user( $db, { username => 'csc_parent', name => 'Cart Payer',
    email => 'csc_parent@test.example' } );
sub child ($name, $family = $parent->id) {
    Registry::DAO::FamilyMember->create( $db, { family_id => $family, child_name => $name, birth_date => '2016-01-01' } );
}
my ( $kid, $sib ) = ( child('Kid'), child('Sib') );

sub session (%o) { scalar make_session( $db, days => [ map { days_from_now($_) } 30 .. 32 ], %o ) }
sub full_price ($s) { session_offer( $db, $s, price_cents => 30000 ) }
sub in_parts ($s) {
    session_offer( $db, $s, price_cents => 27000,
        policies      => { refund => { kind => 'none' }, missed_payment => { kind => 'end' } },
        payment_plans => [ { id => 'pay', kind => 'one_time' }, instalment_plan( id => 'parts', count => 3, cadence => 'weekly' ) ] );
}

# A cart held and owing, each line [ child, session, version, plan ], and its payment step.
sub cart (@lines) { cart_of( $parent, @lines ) }
sub cart_of ( $payer, @lines ) {
    held_cart( $dao, $payer->id, map { [ $_->[0]->id, $_->[1]->id, $_->[2]->id, $_->[3] ] } @lines );
}

sub reload ($run) { Registry::DAO::WorkflowRun->find( $db, { id => $run->id } ) }
sub entitlements_of ($payment) {
    [ map { Registry::DAO::Entitlement->find( $db, { id => $_ } ) }
        $db->select( 'entitlements', 'id', { payment_id => $payment->id }, { -desc => 'payment_share_cents' } )->arrays->flatten->each ];
}
sub schedule_jobs () { $minion->jobs( { tasks => ['instalment_schedule'] } )->total }
sub schedule_job_rows () { $minion->backend->list_jobs( 0, 1000, { tasks => ['instalment_schedule'] } )->{jobs}->@* }
sub schedule_jobs_for ($eid) {
    scalar grep { $_->{args}[0] eq $eid } schedule_job_rows();
}
sub notes_for ($run) {
    $db->query( q{SELECT user_id, type, subject, message FROM notifications
                   WHERE metadata->>'workflow_run_id' = ? ORDER BY id}, $run->id )->hashes->to_array;
}

# Kid at $300 once, Sib at $270 in three weekly parts of $90; paid and driven.
my ( $session, $run, $payment );
my @refunds;
{
    no warnings 'redefine';
    *Registry::Service::Stripe::create_refund_async = sub ( $s, $p ) {
        push @refunds, $p;
        Mojo::Promise->resolve( { id => 're_csc_' . @refunds, status => 'succeeded' } );
    };
}

sub paid_mixed_cart () {
    my $s = session();
    my ( $run, $pay ) = cart( [ $kid, $s, full_price($s), 'pay' ], [ $sib, $s, in_parts($s), 'parts' ] );
    my $payment = started_charge( $db, $run, $pay );
    post_succeeded( $t, $payment, $account )->status_is(200);
    return ( $s, $run, $payment );
}

subtest 'each child holds an entitlement paid by the parent' => sub {
    ( $session, $run, $payment ) = paid_mixed_cart();
    drive($minion);

    my $es = entitlements_of($payment);
    is scalar @$es, 2, 'two entitlements from the one charge' or return;
    is_deeply [ map { $_->holder_family_member_id } @$es ], [ $kid->id, $sib->id ], 'one held by each child';
    is_deeply [ map { $_->holder_user_id } @$es ], [ undef, undef ], 'not by the parent';
    is_deeply [ map { $_->payer_user_id } @$es ], [ ( $parent->id ) x 2 ], 'both paid by the parent';
    is_deeply [ map { $_->payment_share_cents } @$es ], [ 30000, 9000 ], "each with its line's share";
    is_deeply [ map { $_->payment_plan_id } @$es ], [ 'pay', 'parts' ], 'and its plan';
    is_deeply [ map { $_->terms_version } @$es ], [ (Registry::Terms::VERSION) x 2 ], 'stamped with the terms agreed';
    is_deeply [ map { $_->state } @$es ], [qw( active active )], 'active';
    is_deeply [ map { scalar $_->units( $db, $session->id )->@* } @$es ], [ 1, 1 ], 'each holding a seat';
    is $session->free_units($db), 10, 'two of twelve taken';
    is $db->query( q{SELECT count(*) FROM holds WHERE workflow_run_id = ? AND state = 'converted'}, $run->id )
        ->array->[0], 2, 'both holds converted';

    my $after = reload($run);
    ok $after->completed($db), 'the run is complete';
    is $after->latest_step($db)->slug, 'done', 'at the done page';
};

subtest 'one schedule job is queued for the instalment child' => sub {
    my ( $kid_e, $sib_e ) = entitlements_of($payment)->@*;
    is schedule_jobs_for( $sib_e->id ), 1, "one instalment_schedule job for Sib's entitlement";
    is schedule_jobs_for( $kid_e->id ), 0, 'none for Kid, who paid in full';
    my ($job) = grep { $_->{args}[0] eq $sib_e->id } schedule_job_rows();
    is_deeply $job->{args}, [ $sib_e->id, $seller ], 'naming the entitlement and the tenant it lives in';
};

subtest 'the first instalment is dated the UTC day of the charge' => sub {
    my ( $s, $run, $payment ) = paid_mixed_cart();
    # Charged late on a UTC day whose date no location's today need share.
    my $charged = $db->query( q{SELECT to_char((now() AT TIME ZONE 'UTC')::date - 3, 'YYYY-MM-DD')} )->array->[0];
    $db->query( q{UPDATE payments SET completed_at = (?::date + time '23:30') AT TIME ZONE 'UTC' WHERE id = ?},
        $charged, $payment->id );
    drive($minion);

    my $line = Registry::DAO::Payment->find( $db, { id => $payment->id } )->metadata->{lines}[1];
    my $want = Registry::PriceOps::Instalments::due_dates( { count => 3, cadence => 'weekly' }, $charged );
    is_deeply [ map { $_->{due_date} } $line->{parts}->@* ], $want,
        "the parts the schedule reads start on the charge's UTC date";
    is_deeply [ map { $_->{amount_cents} } $line->{parts}->@* ], [ 9000, 9000, 9000 ], 'for the same amounts';
    my ($confirmed) = grep { $_->{type} eq 'enrollment_confirmation' } notes_for($run)->@*;
    like $confirmed->{message}, qr/\$90\.00 paid $want->[0], \$90\.00 due $want->[1], \$90\.00 due $want->[2]\./,
        'and the confirmation gives the due dates as charged';
};

# A drive and a delivery after the checkout is decided add nothing.
subtest 'a second drive changes nothing' => sub {
    my sub state_of () {
        return {
            entitlements => [ map { [ $_->id, $_->unit_count($db) ] } entitlements_of($payment)->@* ],
            free         => $session->free_units($db),
            jobs         => schedule_jobs(),
            notes        => scalar notes_for($run)->@*,
            confirmations => $db->query( q{SELECT count(*) FROM notifications WHERE type = 'enrollment_confirmation'
                                            AND metadata->>'workflow_run_id' = ?}, $run->id )->array->[0],
            refunds      => scalar @refunds,
            outcome      => reload($run)->data->{checkout_outcome},
            step         => reload($run)->latest_step($db)->slug,
        };
    }
    my $before = state_of();
    is scalar $before->{entitlements}->@*, 2, 'the checkout booked two children' or return;

    # The person's return arriving after the driver: the step, again.
    my $workflow = $dao->find( Workflow => { slug => 'session-checkout' } );
    for my $slug (qw( complete done )) {
        my $out = Test::Registry::Async::settle(
            $workflow->get_step( $db, { slug => $slug } )->process( $db, {}, reload($run) ) );
        ok !$out->{errors}, "processing $slug again refuses nothing" or diag explain $out;
    }
    # Another driver, and Stripe delivering the success again.
    $minion->enqueue( continue_workflow_run => [ { tenant => $seller, run_id => $run->id } ] );
    post_succeeded( $t, $payment, $account )->status_is(200);
    drive($minion);

    is_deeply state_of(), $before, 'no entitlement, seat, job, message or refund more';
};

# Child 2's hold lapsed while the parent paid, and the session filled meanwhile.
sub lapse ( $run, $child, $s ) {
    $db->query( q{UPDATE holds SET expires_at = clock_timestamp() - interval '1 second'
                   WHERE workflow_run_id = ? AND id::text = ?}, $run->id, reload($run)->data->{cart_holds}{ $child->id . ':' . $s->id } );
}
sub fill ( $s, $version ) {
    my $other = child( 'Stranger', Test::Registry::Fixtures::create_user( $db, { username => 'csc_other_' . $s->id } )->id );
    Registry::DAO::Entitlement->grant( $db, { holder_family_member_id => $other->id, offer_version_id => $version->id,
        payment_plan_id => 'pay', starts_at => 'now', resource_id => $s->id, units => 1 } );
}

subtest 'a lost seat refunds only its line and schedules nothing' => sub {
    my $s = session( capacity => 2 );
    my ( $full, $split ) = ( full_price($s), in_parts($s) );
    my ( $run, $pay ) = cart( [ $kid, $s, $full, 'pay' ], [ $sib, $s, $split, 'parts' ] );
    my $payment = started_charge( $db, $run, $pay );
    lapse( $run, $sib, $s );
    fill( $s, $full );
    is $s->free_units($db), 0, 'the session is full';

    my ( $jobs, $asked ) = ( schedule_jobs(), scalar @refunds );
    post_succeeded( $t, $payment, $account )->status_is(200);
    drive($minion);

    my $es = entitlements_of($payment);
    is_deeply [ map { $_->holder_family_member_id } @$es ], [ $kid->id ], 'Kid is booked; Sib is not';
    is $es->[0]->payment_share_cents, 30000, "at Kid's share";
    my @new = @refunds[ $asked .. $#refunds ];
    is scalar @new, 1, 'one refund is asked of Stripe';
    is $new[0]{amount}, 9000, "for Sib's share alone";
    is $new[0]{payment_intent}, $payment->stripe_payment_intent_id, 'of the cart charge';
    is $new[0]{_idempotency_key}, join( ':', 'refund:session-line', $run->id, $sib->id, $s->id ),
        'under a key for the run and the line';
    is schedule_jobs(), $jobs, 'no schedule job for Sib';
    is $s->free_units($db), 0, "Sib's lapsed hold took no seat";

    my @notes = notes_for($run)->@*;
    my ($told) = grep { $_->{user_id} eq $parent->id && $_->{type} eq 'general' } @notes;
    ok $told, 'the parent is told' or return;
    like $told->{message}, qr/Sib is not booked into Session \d+; \$90\.00 is being refunded/, 'what was refunded, and why';
    ok( ( grep { $_->{user_id} eq $admin->id } @notes ), 'and the admins' );
    my ($confirmed) = grep { $_->{type} eq 'enrollment_confirmation' } @notes;
    like $confirmed->{message}, qr/\AKid: /, 'Kid is confirmed';
    unlike $confirmed->{message}, qr/Sib:/, 'Sib is not';
    is reload($run)->latest_step($db)->slug, 'done', 'the run is done';
};

subtest 'a lapsed hold with room left is held again and booked' => sub {
    my $s = session( capacity => 3 );
    my ( $run, $pay ) = cart( [ $kid, $s, full_price($s), 'pay' ], [ $sib, $s, in_parts($s), 'parts' ] );
    my $payment = started_charge( $db, $run, $pay );
    lapse( $run, $sib, $s );
    my $asked = @refunds;
    post_succeeded( $t, $payment, $account )->status_is(200);
    drive($minion);

    is_deeply [ map { $_->holder_family_member_id } entitlements_of($payment)->@* ], [ $kid->id, $sib->id ],
        'both children are booked';
    is scalar @refunds, $asked, 'nothing is refunded';
    is $s->free_units($db), 1, 'two of three seats taken';
};

subtest "a sibling price whose sibling lost the seat refunds the whole cart" => sub {
    # A family holding nothing else, so only the cart's sibling counts.
    my $payer = Test::Registry::Fixtures::create_user( $db, { username => 'csc_new_family', name => 'New Family',
        email => 'csc_new_family@test.example' } );
    my ( $kid, $sib ) = map { child( $_, $payer->id ) } qw( Kid Sib );
    my $s = session( capacity => 2 );
    my $regular = full_price($s);
    my $sibling = session_offer( $db, $s, price_cents => 27000, conditions => [ { kind => 'family_holds_entitlement' } ] );
    my ( $run, $pay ) = cart_of( $payer, [ $kid, $s, $regular, 'pay' ], [ $sib, $s, $sibling, 'pay' ] );
    my $payment = started_charge( $db, $run, $pay );
    lapse( $run, $kid, $s );
    fill( $s, $regular );

    my $asked = @refunds;
    post_succeeded( $t, $payment, $account )->status_is(200);
    drive($minion);

    is scalar entitlements_of($payment)->@*, 0, 'nobody is booked';
    my @new = @refunds[ $asked .. $#refunds ];
    is_deeply [ map { $_->{amount} } @new ], [ 30000, 27000 ], 'each line is refunded its share: the whole cart';
    is_deeply [ map { $_->{_idempotency_key} } @new ],
        [ map { join ':', 'refund:session-line', $run->id, $_->id, $s->id } $kid, $sib ], 'under its own key';
    is $s->free_units($db), 1, "Sib's seat is given back";
    my @notes = notes_for($run)->@*;
    my ($told) = grep { $_->{user_id} eq $payer->id && $_->{type} eq 'general' } @notes;
    like $told->{message}, qr/Sib's price was for a child whose brother or sister also has a place/,
        'the parent is told why Sib is refunded too';
    ok !( grep { $_->{type} eq 'enrollment_confirmation' } @notes ), 'and nothing is confirmed';
    is reload($run)->next_step($db)->slug, 'complete', 'the run stays where it says nothing was booked';
};

# Held at 23:55 UTC, charged at 00:05: re-dated from the charge, a weekly plan
# whose last part fell on the session's last day would now end the day after.
subtest 'a plan the charge date pushes past the session is refunded as a lost line' => sub {
    my $s = session( days => [ map { days_from_now($_) } 12 .. 14 ] );
    my ( $run, $pay ) = cart( [ $kid, $s, full_price($s), 'pay' ], [ $sib, $s, in_parts($s), 'parts' ] );
    my $payment = started_charge( $db, $run, $pay );
    post_succeeded( $t, $payment, $account )->status_is(200);
    $db->query( q{UPDATE payments SET completed_at = (((now() AT TIME ZONE 'UTC')::date + 1) + time '00:05') AT TIME ZONE 'UTC'
                   WHERE id = ?}, $payment->id );
    my ( $jobs, $asked ) = ( schedule_jobs(), scalar @refunds );
    drive($minion);

    is_deeply [ map { $_->holder_family_member_id } entitlements_of($payment)->@* ], [ $kid->id ],
        'Kid is booked; Sib, whose plan no longer fits, is not';
    my @new = @refunds[ $asked .. $#refunds ];
    is_deeply [ map { $_->{amount} } @new ], [9000], "Sib's share alone is refunded";
    is schedule_jobs(), $jobs, 'and no schedule is queued';
    my ($told) = grep { $_->{user_id} eq $parent->id && $_->{type} eq 'general' } notes_for($run)->@*;
    like $told->{message}, qr/Sib's payment plan would end after the last day of Session \d+/, 'the parent is told why';
    ok( ( grep { $_->{user_id} eq $admin->id } notes_for($run)->@* ), 'and the admins' );
};

done_testing;
