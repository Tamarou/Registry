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
sub cart (@lines) {
    held_cart( $dao, $parent->id, map { [ $_->[0]->id, $_->[1]->id, $_->[2]->id, $_->[3] ] } @lines );
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
};

done_testing;
