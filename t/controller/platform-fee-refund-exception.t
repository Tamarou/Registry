#!/usr/bin/env perl
# ABOUTME: The platform tenant's admin applies Solo's fee-refund exception to a tenant's refunded payment, over HTTP.
# ABOUTME: Who may, which payments qualify, and that the request is recorded once; the Stripe call is t/stripe-live's.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Mojo::JSON qw( decode_json );
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( authenticate_as import_all_workflows join_tenant );
use Registry;
use Registry::DAO;
use Registry::DAO::Payment;
use Registry::DAO::User;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

my $SOLO_V1      = '00000000-0000-0000-0003-000000000001';
my $NO_EXCEPTION = '00000000-0000-0000-0003-000000000002';    # the platform's 0% offer to itself: refund none

sub a_user ( $name, $role, $slug = 'registry' ) {
    my $user = Test::Registry::Fixtures::create_user( $dao,
        { username => $name, name => $name, email => "$name\@fees.test", user_type => $role } );
    join_tenant( $dao, $user, $role, $slug );
    return $user;
}

my $platform_admin = a_user( 'fee_platform_admin', 'admin' );
my $platform_staff = a_user( 'fee_platform_staff', 'staff' );

my $studio = 'fee_studio';
Test::Registry::Fixtures::create_tenant( $db, { name => 'Fee Studio', slug => $studio } );
my $tdb = $dao->connect_schema($studio)->db;

# A refunded direct charge in $slug's schema that took a 250-cent fee under
# Solo v1; %over changes its columns.
my $n = 0;
sub a_payment (%over) {
    my $slug = delete $over{slug} // $studio;
    my $pdb  = $dao->connect_schema($slug)->db;
    $n++;
    my $parent = Registry::DAO::User->create( $pdb, { username => "fee_parent_$n", name => "Fee Parent $n",
        email => "parent_$n\@fees.test", user_type => 'parent' } );
    my $payment = Registry::DAO::Payment->create( $pdb, {
        user_id      => $parent->id,
        amount_cents => 10000,
        metadata     => { tenant_slug => $slug, stripe_account_id => 'acct_fee_studio' },
    } );
    $pdb->update( 'payments', {
        status                    => 'refunded',
        refunded_cents            => 10000,
        stripe_payment_intent_id  => "pi_fee_exception_$n",
        platform_fee_cents        => 250,
        platform_offer_version_id => $SOLO_V1,
        platform_payment_plan_id  => 'revenue_share',
        %over,
    }, { id => $payment->id } );
    return $payment;
}

sub recorded ($payment, $slug = $studio) {
    my $meta = $dao->connect_schema($slug)->db
        ->query( 'SELECT metadata FROM payments WHERE id = ?', $payment->id )->hash->{metadata};
    return ( decode_json($meta) // {} )->{platform_fee_refund_exception};
}

# A client with its own session, signed in as $user.
sub client ($user) {
    my $t = Test::Registry::Mojo->new('Registry');
    authenticate_as( $t, $user );
    return $t;
}

# Submits the screen's form with %fields and follows the redirect. Returns the
# URL it landed on.
sub submit ( $t, %fields ) {
    my $form = $t->tx->res->dom->at('#workflow-content form');
    ok $form, 'the screen has a form' or return '';
    $t->post_ok( $form->attr('action') => form => \%fields )->status_is(302);
    my $next = $t->tx->res->headers->location;
    $t->get_ok($next)->status_is(200);
    return $next;
}

sub runs_of_workflow () {
    return $db->query( q{SELECT count(*) FROM workflow_runs r JOIN workflows w ON w.id = r.workflow_id
                          WHERE w.slug = 'platform-fee-refund-exception'} )->array->[0];
}

subtest 'platform-fee-refund-exception admits admin and refuses staff' => sub {
    client($platform_admin)->get_ok('/platform-fee-refund-exception')->status_is(200)
        ->element_exists( '#workflow-content form', 'an admin of registry is shown the first screen' );

    my $before = runs_of_workflow();
    client($platform_staff)->get_ok('/platform-fee-refund-exception')->status_is(403);
    is runs_of_workflow(), $before, 'no run is created for staff';
};

subtest 'platform admin records fee refund exception once' => sub {
    my $payment = a_payment();
    my $t = client($platform_admin);
    $t->get_ok('/platform-fee-refund-exception')->status_is(200);
    like submit( $t, payment_tenant => $studio, payment_id => $payment->id ), qr{/confirm\z}, 'on to confirm';
    $t->content_like( qr/\$2\.50/, 'the fee to return is shown' )->content_like( qr/Solo/, 'with the terms it was taken under' );

    like submit( $t, reason => 'Our outage charged the family twice' ), qr{/apply\z}, 'on to apply';

    my $request = recorded($payment);
    is $request->{idempotency_key}, 'platform-fee-refund:' . $payment->id, 'under a key derived from the payment';
    is $request->{reason}, 'Our outage charged the family twice', 'with the admin reason';
    is $request->{amount_cents}, 250, 'for the whole fee not yet returned';
    is $request->{platform_offer_version_id}, $SOLO_V1, 'under the stamped platform offer version';
    is $request->{requested_by}, $platform_admin->id, 'by the admin';
    ok $request->{requested_at}, 'and when';
};

done_testing;
