#!/usr/bin/env perl
# ABOUTME: The entitlement-refund workflow over HTTP: choose a booking, read its refund terms, request the refund.
# ABOUTME: Only its holder or payer, or the tenant's admin or staff, may ask; Stripe's answer is in t/stripe-live/.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( authenticate_as import_all_workflows join_tenant );
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO;
use Registry::DAO::Entitlement;
use Registry::DAO::Offer;
use Registry::DAO::Payment;
use Registry::DAO::Resource;
use Registry::DAO::WorkflowRun;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

my $made = 0;

sub member ( $role, $type = $role ) {
    my $n    = ++$made;
    my $user = Test::Registry::Fixtures::create_user( $dao, {
        username => "er_${role}_$n", name => "ER $role $n", email => "er_${role}_$n\@refund.test",
        user_type => $type } );
    join_tenant( $dao, $user, $role );
    return $user;
}

my $teacher = member('staff');

# An occurrence 48 hours off, sold by a published version of an offer named
# $name under refund policy $refund.
sub offer ( $refund, $name = 'Wheel class ' . ++$made ) {
    my $class = $db->insert( 'projects', { name => 'Class ' . ++$made, slug => "er-class-$made" },
        { returning => 'id' } )->hash->{id};
    my $room = $db->insert( 'locations', { name => 'Room ' . ++$made, slug => "er-room-$made" },
        { returning => 'id' } )->hash->{id};
    my $event = $db->insert( 'events', {
        project_id => $class, location_id => $room, teacher_id => $teacher->id,
        time       => \"now() + interval '48 hours'", duration => 90, capacity => 4,
    }, { returning => 'id' } )->hash->{id};
    my $occurrence = Registry::DAO::Resource->for_occurrence( $db, $event );
    my $version = Registry::DAO::Offer->create( $db, { name => $name } )
        ->draft( $db, offer_terms( $occurrence->id, policies => { refund => $refund } ) )
        ->publish($db);
    return ( $version, $occurrence );
}

# $holder's seat under $refund, paid $share cents of a 5000-cent payment. The
# payment names no seller account, so its refund is refused before anything
# reaches Stripe. Returns the entitlement and the payment.
sub booking ( $holder, $refund, $name = undef ) {
    my ( $version, $occurrence ) = offer( $refund, $name // () );
    my $paid = Registry::DAO::Payment->create( $db, {
        user_id => $holder->id, amount_cents => 5000, status => 'completed',
        stripe_payment_intent_id => 'pi_er_' . ++$made, metadata => {} } );
    my ( undef, $ends ) = $occurrence->occurrence_window($db);
    my $e = Registry::DAO::Entitlement->grant( $db, {
        holder_user_id => $holder->id, offer_version_id => $version->id, payment_plan_id => 'pay',
        starts_at => '2020-01-01T00:00:00Z', ends_at => $ends, resource_id => $occurrence->id, units => 1,
        payment_id => $paid->id, payment_share_cents => 3000 } );
    return ( $e, $paid );
}

# A client with its own session, signed in as $user (none for anonymous).
sub client ( $user = undef ) {
    my $t = Test::Registry::Mojo->new('Registry');
    authenticate_as( $t, $user ) if $user;
    return $t;
}

sub run_of ($url) {
    my ($id) = ( $url // '' ) =~ m{/entitlement-refund/([0-9a-f-]{36})/};
    return $id && Registry::DAO::WorkflowRun->find( $db, { id => $id } );
}

sub form_of ($t) { $t->tx->res->dom->at('#workflow-content form') }

# Submits the page's form with %fields and follows the redirect. Returns the next URL.
sub submit ( $t, %fields ) {
    my $form = form_of($t) or return fail 'the page has a form';
    $t->post_ok( $form->attr('action') => form => \%fields )->status_is(302);
    my $next = $t->tx->res->headers->location;
    $t->get_ok($next)->status_is(200);
    return $next;
}

sub runs () {
    $db->query( q{SELECT count(*) FROM workflow_runs r JOIN workflows w ON w.id = r.workflow_id
                   WHERE w.slug = 'entitlement-refund'} )->array->[0];
}

# The refund requested of $paid for $e, if any.
sub request_on ( $paid, $e ) {
    ( Registry::DAO::Payment->find( $db, { id => $paid->id } )->metadata->{entitlement_refund_requests} // {} )
        ->{ $e->id };
}

subtest 'customer gets stamped policy outcome' => sub {
    my $holder = member('parent');
    my ( $e, $paid ) = booking( $holder, { kind => 'none' } );

    my $t = client($holder);
    $t->get_ok('/entitlement-refund')->status_is(200);
    ok form_of($t)->at( 'input[name="entitlement_id"][value="' . $e->id . '"]' ), 'the holder is offered their booking';
    like submit( $t, entitlement_id => $e->id ), qr{/apply\z}, 'on to the refund terms';
    $t->content_like( qr/all sales are final/i, "the offer's refund terms are shown" );
    like submit($t), qr{/done\z}, 'asking lands on the done page';
    $t->content_like( qr/all sales are final: it gives no refunds/i, 'the customer is told the sale is final' );

    is request_on( $paid, $e ), undef, 'no refund is requested';
    is Registry::DAO::Entitlement->find( $db, { id => $e->id } )->state, 'active', 'the booking is unchanged';
};

subtest 'entitlement-refund admits parent admin and staff and refuses an anonymous visitor' => sub {
    client( member($_) )->get_ok('/entitlement-refund')->status_is( 200, "a $_ reaches the workflow" )
        for qw( parent admin staff );
    my $before = runs();
    client()->get_ok('/entitlement-refund')->status_is(302);
    is runs(), $before, 'an anonymous visitor creates no run';
};

done_testing;
