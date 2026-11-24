#!/usr/bin/env perl
# ABOUTME: The platform tenant's admin applies Solo's fee-refund exception to a tenant's refunded payment, over HTTP.
# ABOUTME: Who may, which payments qualify, and that the request is recorded once; the Stripe call is t/stripe-live's.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Mojo::File ();
use Mojo::JSON qw( decode_json );
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( authenticate_as import_all_workflows join_tenant );
use Registry;
use Registry::DAO;
use Registry::DAO::Payment;
use Registry::DAO::User;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;

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
# As provisioning gives a tenant every workflow, so its admins reach the route.
Registry::DAO::Workflow->from_yaml( $dao->connect_schema($studio),
    Mojo::File::path('workflows/platform-fee-refund-exception.yml')->slurp );

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

# Each step of the workflow, driven directly with the server-owned keys a
# request carries ($user acting as $acting) on a run that has already found
# $payment in $slug -- so the later steps are asked too, not just the first.
my $workflow = Registry::DAO::Workflow->find( $db, { slug => 'platform-fee-refund-exception' } );
sub step_result ( $step_slug, $user, $acting, $payment, %form ) {
    my $run = $workflow->new_run($db);
    $run->update_data( $db, { fee_refund_payment => { tenant => $form{slug} // $studio, payment_id => $payment->id } } );
    my $step = Registry::DAO::WorkflowStep->find( $db, { workflow_id => $workflow->id, slug => $step_slug } );
    return $step->process( $db, {
        payment_tenant => $form{slug} // $studio, payment_id => $payment->id, reason => 'a reason',
        %form, __tenant_slug => $acting, user_id => $user->id }, $run );
}

sub refused_at_every_step ( $user, $acting, $why ) {
    my $payment = a_payment();
    for my $slug (qw( find-payment confirm apply )) {
        my $result = step_result( $slug, $user, $acting, $payment );
        like( ( $result->{errors} // [] )->[0] // '', $why, "refused at $slug" );
    }
    is recorded($payment), undef, 'nothing is recorded';
}

# Walks find-payment over HTTP as $user acting as $acting and returns the
# error the screen shows, or ''.
sub find_refusal ( $user, $acting, %fields ) {
    my $t = client($user);
    my %as = $acting eq 'registry' ? () : ( 'X-As-Tenant' => $acting );
    $t->get_ok( '/platform-fee-refund-exception' => \%as )->status_is(200);
    my $form = $t->tx->res->dom->at('#workflow-content form');
    $t->post_ok( $form->attr('action') => \%as => form => \%fields )->status_is(302);
    my $next = $t->tx->res->headers->location;
    unlike $next, qr{/confirm\z}, 'the run does not move on';
    $t->get_ok( $next => \%as )->status_is(200);
    my $alert = $t->tx->res->dom->at('#workflow-content .alert-error');
    return $alert ? $alert->all_text : '';
}

my $OPERATOR = qr/Only an admin of the platform tenant/;

subtest 'other tenant admin refused' => sub {
    my $studio_admin = a_user( 'fee_studio_admin', 'admin', $studio );
    my $payment = a_payment();
    like find_refusal( $studio_admin, $studio, payment_tenant => $studio, payment_id => $payment->id ),
        $OPERATOR, 'an admin of the studio is refused, over HTTP';
    refused_at_every_step( $studio_admin, $studio, $OPERATOR );
};

subtest 'registry staff refused' => sub {
    my $t = client($platform_staff);
    $t->get_ok('/platform-fee-refund-exception')->status_is(403, 'staff are refused at the route');
    refused_at_every_step( $platform_staff, 'registry', $OPERATOR );
};

subtest 'platform admin acting as tenant refused' => sub {
    # A member there as admin too, so the route admits them and the steps must refuse.
    join_tenant( $dao, $platform_admin, 'admin', $studio );
    my $payment = a_payment();
    like find_refusal( $platform_admin, $studio, payment_tenant => $studio, payment_id => $payment->id ),
        $OPERATOR, 'acting as the studio, over HTTP';
    refused_at_every_step( $platform_admin, $studio, $OPERATOR );
};

subtest 'payment without admin exception refused' => sub {
    for my $case (
        [ 'a version whose refund policy is none', platform_offer_version_id => $NO_EXCEPTION ],
        [ 'no stamped version', platform_offer_version_id => undef, platform_payment_plan_id => undef ],
    ) {
        my ( $label, %over ) = @$case;
        my $payment = a_payment(%over);
        like find_refusal( $platform_admin, 'registry', payment_tenant => $studio, payment_id => $payment->id ),
            qr/not charged under platform terms that allow the fee to be returned/, "refused: $label";
        for my $slug (qw( confirm apply )) {
            like( ( step_result( $slug, $platform_admin, 'registry', $payment )->{errors} // [] )->[0] // '',
                qr/allow the fee to be returned/, "and at $slug: $label" );
        }
        is recorded($payment), undef, "nothing is recorded: $label";
    }
};

subtest 'unrefunded payment refused' => sub {
    my $payment = a_payment( status => 'completed', refunded_cents => 0 );
    like find_refusal( $platform_admin, 'registry', payment_tenant => $studio, payment_id => $payment->id ),
        qr/has not been refunded/, 'a completed payment is refused';
    like( ( step_result( 'confirm', $platform_admin, 'registry', $payment )->{errors} // [] )->[0] // '',
        qr/has not been refunded/, 'and at confirm' );
    is recorded($payment), undef, 'nothing is recorded';
};

subtest 'empty reason refused' => sub {
    my $payment = a_payment();
    for my $reason ( '', "  \n\t " ) {
        like( ( step_result( 'confirm', $platform_admin, 'registry', $payment, reason => $reason )->{errors} // [] )->[0] // '',
            qr/reason/i, 'a blank reason is refused' );
    }
    like( ( step_result( 'confirm', $platform_admin, 'registry', $payment, reason => undef )->{errors} // [] )->[0] // '',
        qr/reason/i, 'and a missing one' );
    is recorded($payment), undef, 'nothing is recorded';
};

subtest 'exception applied twice records once' => sub {
    my $payment = a_payment();
    ok !step_result( 'confirm', $platform_admin, 'registry', $payment, reason => 'First' )->{errors}, 'first application';
    my $first = recorded($payment);
    $dao->connect_schema($studio)->db->update( 'payments', { platform_fee_cents => 400 }, { id => $payment->id } );
    ok !step_result( 'confirm', $platform_admin, 'registry', $payment, reason => 'Second' )->{errors},
        'a second application is answered';
    is_deeply recorded($payment), $first, 'and leaves the first request as it was';
};

subtest 'fee refund capped at remaining fee' => sub {
    my $part = a_payment( platform_fee_refunded_cents => 100 );
    ok !step_result( 'confirm', $platform_admin, 'registry', $part, reason => 'Ours' )->{errors}, 'recorded';
    is recorded($part)->{amount_cents}, 150, 'for the 250-cent fee less the 100 already returned';

    my $all = a_payment( platform_fee_refunded_cents => 250 );
    like find_refusal( $platform_admin, 'registry', payment_tenant => $studio, payment_id => $all->id ),
        qr/None of the platform fee/, 'a fee already returned in full is refused';
    is recorded($all), undef, 'and nothing is recorded';

    my $none = a_payment( platform_fee_cents => undef );
    like find_refusal( $platform_admin, 'registry', payment_tenant => $studio, payment_id => $none->id ),
        qr/None of the platform fee/, 'a payment that recorded no fee is refused';
};

subtest 'apply finishes when the fee is already returned' => sub {
    my $payment = a_payment();
    my $t = client($platform_admin);
    $t->get_ok('/platform-fee-refund-exception')->status_is(200);
    submit( $t, payment_tenant => $studio, payment_id => $payment->id );
    like submit( $t, reason => 'Ours' ), qr{/apply\z}, 'the request is recorded';

    # Stripe reported the whole fee returned (an earlier press, or by hand).
    $dao->connect_schema($studio)->db->update( 'payments', { platform_fee_refunded_cents => 250 }, { id => $payment->id } );
    like submit($t), qr{/complete\z}, 'apply lands on complete, sending nothing';
    $t->content_like( qr/\$2\.50 of the fee was already returned/, 'saying the fee was already returned' );
};

subtest 'unknown tenant slug refused before connecting' => sub {
    my $payment = a_payment();
    for my $slug ( q{fee_studio'; DROP SCHEMA fee_studio CASCADE; --}, 'no_such_studio', 'fee_studio, registry' ) {
        like find_refusal( $platform_admin, 'registry', payment_tenant => $slug, payment_id => $payment->id ),
            qr/There is no tenant with that slug/, "refused: $slug";
    }
    ok $db->query( q{SELECT 1 FROM information_schema.schemata WHERE schema_name = 'fee_studio'} )->rows,
        'the studio schema is still there';
};

subtest 'payment under wrong tenant not found' => sub {
    Test::Registry::Fixtures::create_tenant( $db, { name => 'Other Studio', slug => 'other_studio' } );
    my $payment = a_payment();
    like find_refusal( $platform_admin, 'registry', payment_tenant => 'other_studio', payment_id => $payment->id ),
        qr/That tenant has no payment with that id/, 'a studio payment looked up under another tenant';
    like find_refusal( $platform_admin, 'registry', payment_tenant => $studio, payment_id => 'not-a-uuid' ),
        qr/That tenant has no payment with that id/, 'and an id that is no uuid';
};

done_testing;
