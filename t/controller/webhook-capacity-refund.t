# ABOUTME: A late cart line refunded: a seat lost while the parent paid is refunded after the webhook's COMMIT, by the run's driver.
# ABOUTME: Delivered to the Connect endpoint. Covers tenant routing by event.account, ordering after COMMIT, retries, and that Stripe always gets 2xx.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::PricingProbe qw( state_platform_terms );
use Test::Registry::Mojo;
use Test::Registry::Sessions qw( make_session session_offer held_cart );
use Test::Registry::SessionCheckout qw( started_charge post_succeeded drive );
use Registry::DAO;
use Registry::DAO::Entitlement;
use Registry::DAO::FamilyMember;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Payment;
use Registry::DAO::WorkflowRun;
use Registry::Service::Stripe;
use Mojo::Promise;

local $ENV{STRIPE_SECRET_KEY}             = 'sk_test_capacity_refund';
local $ENV{STRIPE_WEBHOOK_SECRET}         = 'whsec_test_capacity_refund';
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_test_capacity_refund_connect';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $slug    = 'cr_tenant_' . $$;
my $account = 'acct_cr_test';
my $admin   = Registry::DAO::User->create( $db, {
    username => "cr_admin_$$", email => "cr_admin_$$\@test.example", name => 'CR Admin', user_type => 'admin' } );
Registry::DAO::Tenant->provision( $db, {
    name => "CR Tenant $$", slug => $slug, users => [$admin], stripe_connect_account_id => $account,
    stripe_charges_enabled => 1, stripe_details_submitted => 1 } );
state_platform_terms( $db, $slug, { rate => 0 } );
my $tdao = Registry::DAO->new( url => $test_db->uri, schema => $slug );
my $tdb  = $tdao->db;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub ( $c, $tenant = undef ) {
    defined $tenant ? Registry::DAO->new( url => $test_db->uri, schema => $tenant ) : $dao } );
my $minion = $t->app->minion;

my $parent = Registry::DAO::User->create( $tdb, {
    username => "cr_parent_$$", email => "cr_parent_$$\@test.example", name => 'CR Parent', user_type => 'parent' } );
my $seq = 0;
sub a_child ( $family = $parent->id ) {
    Registry::DAO::FamilyMember->create( $tdb, { family_id => $family, child_name => 'CR Kid ' . ++$seq, birth_date => '2018-01-01' } );
}
my $stranger = Registry::DAO::User->create( $tdb, {
    username => "cr_stranger_$$", email => "cr_stranger_$$\@test.example", name => 'CR Other', user_type => 'parent' } );

# A paid cart of two children in a two-seat session, whose second child's hold
# lapsed while the parent paid and whose seat another family then took: the
# first child is booked, the second's $150 line is late.
sub a_late_line () {
    my $session = make_session( $tdb, capacity => 2 );
    my $version = session_offer( $tdb, $session, price_cents => 15000 );
    my ( $first, $late ) = ( a_child(), a_child() );
    my ( $run, $pay ) = held_cart( $tdao, $parent->id,
        map { [ $_->id, $session->id, $version->id, 'pay' ] } $first, $late );
    my $payment = started_charge( $tdb, $run, $pay );
    $tdb->query( q{UPDATE holds SET expires_at = clock_timestamp() - interval '1 second' WHERE id::text = ?},
        Registry::DAO::WorkflowRun->find( $tdb, { id => $run->id } )->data->{cart_holds}{ $late->id . ':' . $session->id } );
    Registry::DAO::Entitlement->grant( $tdb, { holder_family_member_id => a_child( $stranger->id )->id,
        offer_version_id => $version->id, payment_plan_id => 'pay', starts_at => 'now',
        resource_id => $session->id, units => 1 } );
    return { run => $run, payment => $payment, session => $session, first => $first, late => $late };
}

sub tenant_payment ($payment) { Registry::DAO::Payment->find( $tdb, { id => $payment->id } ) }
sub booked ($cart) {
    [ map { $_->{holder_family_member_id} } $tdb->select( 'entitlements', '*', { payment_id => $cart->{payment}->id } )->hashes->@* ];
}

# Drives with Stripe's refund create answering as $answer does.
sub drive_refunding ( $answer, $calls = [] ) {
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_refund_async = sub ( $s, $p ) { push @$calls, $p; $answer->($p) };
    # Retried at once rather than after the backoff.
    my $backoff = $minion->backoff;
    $minion->backoff( sub ($retries) { 0 } );
    drive($minion);
    $minion->backoff($backoff);
    return $calls;
}
my $succeeds = sub ($p) { Mojo::Promise->resolve( { id => 're_cr_' . $p->{_idempotency_key}, status => 'succeeded' } ) };

subtest 'a late line refund settles in the account resolved tenant' => sub {
    my $cart = a_late_line();
    post_succeeded( $t, $cart->{payment}, $account )->status_is(200);
    my $refunds = drive_refunding($succeeds);

    is scalar @$refunds, 1, 'the late line is refunded';
    is $refunds->[0]{amount}, 15000, "for the late child's share";
    is_deeply booked($cart), [ $cart->{first}->id ], 'the first child is booked, the late one is not';

    # By qualified name on both sides: an assertion reading whatever unqualified
    # `payments` resolves to would pass even if the write had landed in the
    # wrong schema, which is the failure this guards.
    my $in_tenant = $db->query( sprintf( q{SELECT status, refunded_cents FROM %s.payments WHERE id = ?},
        $db->dbh->quote_identifier($slug) ), $cart->{payment}->id )->hash;
    is $in_tenant->{status}, 'partially_refunded', 'the tenant row records the refund';
    is $in_tenant->{refunded_cents}, 15000, 'of the late line alone';
    is $db->query( 'SELECT COUNT(*) FROM registry.payments WHERE id = ?', $cart->{payment}->id )->array->[0], 0,
        'and registry.payments gained nothing';
};

subtest 'the refund happens after the COMMIT, not inside it' => sub {
    my $cart = a_late_line();
    my @during;
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async = sub ( $s, $p ) {
            push @during, $p;
            Mojo::Promise->resolve( { id => 're_cr_inside', status => 'succeeded' } );
        };
        post_succeeded( $t, $cart->{payment}, $account )->status_is(200);
    }
    is scalar @during, 0, 'the webhook itself asks Stripe for nothing';
    is tenant_payment( $cart->{payment} )->status, 'completed', 'the committed payment is completed';
    is $minion->jobs( { tasks => ['continue_workflow_run'], states => ['inactive'] } )->total, 1,
        "and the run's driver is queued to book and refund";
    is scalar drive_refunding($succeeds)->@*, 1, 'which refunds the late line';
};

subtest 'a rejected refund still answers Stripe with 2xx, and the driver retries it' => sub {
    my $cart  = a_late_line();
    my $tries = 0;
    post_succeeded( $t, $cart->{payment}, $account )->status_is( 200, 'acknowledged before any refund' );
    drive_refunding( sub ($p) { $tries++; Mojo::Promise->reject("Stripe api_error: try later\n") } );

    is $tries, 3, 'asked on each of the three attempts';
    is_deeply booked($cart), [ $cart->{first}->id ], 'the first child stays booked';
    my $run = Registry::DAO::WorkflowRun->find( $tdb, { id => $cart->{run}->id } );
    is $run->data->{__driver}{state}, 'halted', 'the run is halted for an admin on the last attempt';
    like tenant_payment( $cart->{payment} )->metadata->{refund_last_failure}{message}, qr/try later/,
        'the failure is recorded on the payment';
    is tenant_payment( $cart->{payment} )->refunded_cents, 0, 'and nothing is recorded as refunded';
};

subtest 'redelivered event settles once' => sub {
    my $cart = a_late_line();
    post_succeeded( $t, $cart->{payment}, $account )->status_is(200);
    my $refunds = drive_refunding($succeeds);
    post_succeeded( $t, $cart->{payment}, $account )->status_is(200);
    drive_refunding( $succeeds, $refunds );

    is scalar @$refunds, 1, 'the late line is refunded once';
    is scalar booked($cart)->@*, 1, 'and one child booked once';
    is tenant_payment( $cart->{payment} )->refunded_cents, 15000, 'with one refund recorded';
};

done_testing;
