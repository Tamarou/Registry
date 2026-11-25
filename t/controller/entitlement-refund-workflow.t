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
use Registry::DAO::Tenant;
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

my $full = { kind => 'full_until_cutoff', cutoff_hours => 24 };

# $user walks to the refund terms of $e. Returns the client and the apply URL.
sub to_terms ( $user, $e ) {
    my $t = client($user);
    $t->get_ok( '/entitlement-refund?entitlement_id=' . $e->id )->status_is(200);
    my $action = form_of($t)->attr('action');
    like $action, qr{/apply\z}, 'the link lands on the refund terms';
    return ( $t, $action );
}

subtest 'customer asks before the cutoff and the refund is requested' => sub {
    my $holder = member('parent');
    my ( $e, $paid ) = booking( $holder, $full );
    my ( $t, $action ) = to_terms( $holder, $e );
    $t->content_like( qr/full refund until 24 hours before the class starts/i, 'the cutoff is shown' );
    $t->post_ok( $action => form => {} );
    is_deeply request_on( $paid, $e ), { amount_cents => 3000, idempotency_key => 'refund:entitlement:' . $e->id },
        "a refund of the booking's share is requested";
    # This payment names no seller account, so Stripe is never asked; the walk
    # to the done page against Stripe is t/stripe-live/refund-policy-full-until-cutoff.t.
    $t->get_ok( $t->tx->res->headers->location )->content_like( qr/Nothing was sent to Stripe/ );
    is Registry::DAO::Entitlement->find( $db, { id => $e->id } )->state, 'active',
        "the booking waits for Stripe's report to end it";
};

subtest 'keep the fee points to the fee-refund exception' => sub {
    my $holder = member('parent');
    my ( $e, $paid ) = booking( $holder, { kind => 'keep_fee_with_admin_exception' } );
    my ( $t ) = to_terms( $holder, $e );
    like submit($t), qr{/done\z}, 'asking lands on the done page';
    $t->content_like( qr/admin.*fee-refund exception/i, 'the customer is sent to the admin and the exception' );
    is request_on( $paid, $e ), undef, 'no refund is requested';
};

subtest 'stranger cannot choose entitlement' => sub {
    my $holder = member('parent');
    my ( $e, $paid ) = booking( $holder, $full );

    my $stranger = member('parent');
    my $t = client($stranger);
    $t->get_ok( '/entitlement-refund?entitlement_id=' . $e->id )->status_is(200);
    ok !form_of($t)->at( 'input[name="entitlement_id"][value="' . $e->id . '"]' ), 'the booking is not offered';
    my $action = form_of($t)->attr('action');
    like $action, qr{/choose\z}, 'a link to someone else\'s booking does not get past choosing';
    $t->post_ok( $action => form => { entitlement_id => $e->id } )->status_is(302);
    $t->get_ok( $t->tx->res->headers->location )->content_like( qr/not yours to refund/i, 'posting it is refused' );
    ok !run_of($action)->data->{refund_entitlement_id}, 'the run names no booking to refund';

    # Nor can they submit it on the holder's own run.
    my ( undef, $holder_apply ) = to_terms( $holder, $e );
    client($stranger)->post_ok( $holder_apply => form => {} );
    is request_on( $paid, $e ), undef, 'posting to the holder\'s run requests no refund';
};

subtest 'unauthenticated visitor sent to sign in' => sub {
    my ( $e, $paid ) = booking( member('parent'), $full );
    client()->get_ok( '/entitlement-refund?entitlement_id=' . $e->id )->status_is(302)
        ->header_like( Location => qr{/auth/login} );
    is request_on( $paid, $e ), undef, 'no refund is requested';
};

subtest 'other tenant entitlement not found' => sub {
    my $slug  = "er_other_$$";
    my $owner = member('admin');
    Registry::DAO::Tenant->provision( $db, { name => "ER Other $$", slug => $slug, users => [$owner] } );
    my $other = $dao->connect_schema($slug)->db;
    my $room  = $other->insert( 'locations', { name => 'Far room', slug => 'far-room' }, { returning => 'id' } )->hash->{id};
    my $class = $other->insert( 'projects', { name => 'Far class', slug => 'far-class' }, { returning => 'id' } )->hash->{id};
    my $teach = $other->insert( 'users', { username => "er-far-$$" }, { returning => 'id' } )->hash->{id};
    my $occurrence = Registry::DAO::Resource->for_occurrence( $other, $other->insert( 'events', {
        project_id => $class, location_id => $room, teacher_id => $teach,
        time => \"now() + interval '48 hours'", duration => 90, capacity => 4 }, { returning => 'id' } )->hash->{id} );
    my $version = Registry::DAO::Offer->create( $other, { name => 'Far wheel' } )
        ->draft( $other, offer_terms( $occurrence->id, policies => { refund => $full } ) )->publish($other);
    my $paid = Registry::DAO::Payment->create( $other, {
        user_id => $teach, amount_cents => 5000, status => 'completed',
        stripe_payment_intent_id => "pi_er_far_$$", metadata => {} } );
    my $e = Registry::DAO::Entitlement->grant( $other, {
        holder_user_id => $teach, offer_version_id => $version->id, payment_plan_id => 'pay',
        starts_at => '2020-01-01T00:00:00Z', resource_id => $occurrence->id, units => 1,
        payment_id => $paid->id, payment_share_cents => 3000 } );

    my $t = client( member('admin') );
    $t->get_ok( '/entitlement-refund?entitlement_id=' . $e->id )->status_is(200);
    my $action = form_of($t)->attr('action');
    $t->post_ok( $action => form => { entitlement_id => $e->id } )->status_is(302);
    $t->get_ok( $t->tx->res->headers->location )->content_like(qr/Choose a booking to refund/);
    ok !run_of($action)->data->{refund_entitlement_id}, 'the other tenant\'s booking is not found';
    ok !Registry::DAO::Payment->find( $other, { id => $paid->id } )->metadata->{entitlement_refund_requests},
        'no refund is requested';
};

subtest 'double submit requests one refund' => sub {
    my $holder = member('parent');
    my ( $e, $paid ) = booking( $holder, $full );
    my ( $t, $action ) = to_terms( $holder, $e );
    $t->post_ok( $action => form => {} ) for 1 .. 2;
    my $requests = Registry::DAO::Payment->find( $db, { id => $paid->id } )->metadata->{entitlement_refund_requests};
    is_deeply $requests, { $e->id => { amount_cents => 3000, idempotency_key => 'refund:entitlement:' . $e->id } },
        'one request for the share, under the one key Stripe sees';
};

subtest 'refund terms rendered escaped' => sub {
    my $holder = member('parent');
    my ( $e ) = booking( $holder, $full, '<script>alert("er")</script><b>Bold wheel</b>' );
    my ( $t ) = to_terms( $holder, $e );
    $t->content_like( qr/&lt;script&gt;alert/, "the offer's words are shown escaped" )
        ->content_unlike( qr/<script>alert/, 'and never as a script' )
        ->content_unlike( qr/<b>Bold wheel/, 'or as markup' );
};

subtest 'ended entitlement not offered' => sub {
    my $holder = member('parent');
    my ( $e, $paid ) = booking( $holder, $full );
    $e->end( $db, 'refunded', 're_er_ended' );

    my $t = client($holder);
    $t->get_ok('/entitlement-refund')->status_is(200);
    ok !$t->tx->res->dom->at( 'input[name="entitlement_id"][value="' . $e->id . '"]' ), 'the ended booking is not offered';
    my $action = form_of($t)->attr('action');
    $t->post_ok( $action => form => { entitlement_id => $e->id } )->status_is(302);
    $t->get_ok( $t->tx->res->headers->location )->content_like( qr/has ended/i, 'posting its id is refused' );
    ok !run_of($action)->data->{refund_entitlement_id}, 'the run names no booking to refund';
    is request_on( $paid, $e ), undef, 'no refund is requested';
};

done_testing;
