#!/usr/bin/env perl
# ABOUTME: The entitlement-change workflow over HTTP: choose, hold, pay the fee (none on a zero fee), complete.
# ABOUTME: Only the entitlement's holder or payer, or the tenant's admin or staff, may change it; nothing is held otherwise.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( authenticate_as import_all_workflows join_tenant );
use Test::Registry::PricingProbe qw( give_tenant_terms );
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO;
use Registry::DAO::Entitlement;
use Registry::DAO::Offer;
use Registry::DAO::Payment;
use Registry::DAO::Resource;
use Registry::DAO::Tenant;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::PriceOps::Hold;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

# The platform tenant sells the class, so a change fee has an account and terms to be charged under.
Test::Registry::Fixtures::platform_seller($db);
$db->query( q{UPDATE registry.tenants SET stripe_charges_enabled = true, stripe_details_submitted = true
               WHERE slug = 'registry'} );
give_tenant_terms( $db, 'registry', { rate => '0.025' } );

my $made = 0;

sub member ( $role, $type = $role ) {
    my $n    = ++$made;
    my $user = Test::Registry::Fixtures::create_user( $dao, {
        username => "ec_${role}_$n", name => "EC $role $n", email => "ec_${role}_$n\@change.test",
        user_type => $type } );
    join_tenant( $dao, $user, $role );
    return $user;
}

my $teacher = member('staff');

# A class whose occurrences start $hours from now, each with $capacity seats,
# and a published offer version covering them with a 48-hour change window
# costing $fee cents. Returns the version and the occurrences' resources.
sub occurrences ( $fee, $capacity, @hours ) {
    my $class = $db->insert( 'projects', { name => 'Class ' . ++$made, slug => "ec-class-$made" },
        { returning => 'id' } )->hash->{id};
    my @resources = map {
        my $room = $db->insert( 'locations', { name => 'Room ' . ++$made, slug => "ec-room-$made" },
            { returning => 'id' } )->hash->{id};
        my $event = $db->insert( 'events', {
            project_id => $class, location_id => $room, teacher_id => $teacher->id,
            time       => \"now() + interval '$_ hours'", duration => 90, capacity => $capacity,
        }, { returning => 'id' } )->hash->{id};
        Registry::DAO::Resource->for_occurrence( $db, $event );
    } @hours;
    my $version = Registry::DAO::Offer->create( $db, { name => 'Wheel class ' . $made } )
        ->draft( $db, offer_terms( undef, class_project_id => $class, policies => {
            refund => { kind => 'none' },
            change => { kind => 'window', window_hours => 48, fee_cents => $fee, targets => 'same_offer' },
            expiry => { kind => 'end_of_occurrence' } } ) )
        ->publish($db);
    return ( $version, @resources );
}

# $holder's entitlement under $version to $units seats of $resource.
sub booking ( $version, $resource, $holder, $units = 1 ) {
    my ( undef, $ends ) = $resource->occurrence_window($db);
    return Registry::DAO::Entitlement->grant( $db, {
        holder_user_id   => $holder->id,
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
        starts_at        => '2020-01-01T00:00:00Z',
        ends_at          => $ends,
        resource_id      => $resource->id,
        units            => $units,
    } );
}

# A client with its own session, signed in as $user (none for anonymous).
sub client ( $user = undef ) {
    my $t = Test::Registry::Mojo->new('Registry');
    authenticate_as( $t, $user ) if $user;
    return $t;
}

# The run a step URL names.
sub run_of ($url) {
    my ($id) = ( $url // '' ) =~ m{/entitlement-change/([0-9a-f-]{36})/};
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

sub holds_on ($resource) {
    my $live = Registry::PriceOps::Hold->live_sql('holds');
    $db->query( "SELECT count(*) FROM holds WHERE resource_id = ? AND $live", $resource->id )->array->[0];
}

sub runs () {
    $db->query( q{SELECT count(*) FROM workflow_runs r JOIN workflows w ON w.id = r.workflow_id
                   WHERE w.slug = 'entitlement-change'} )->array->[0];
}

sub payments_of ($run) {
    $db->query( q{SELECT count(*) FROM payments WHERE metadata->>'workflow_run_id' = ?}, $run->id )->array->[0];
}

# $holder walks a change of $e to $to as far as the payment page. Returns the client and the run.
sub to_payment ( $holder, $e, $to ) {
    my $t = client($holder);
    $t->get_ok( '/entitlement-change?entitlement_id=' . $e->id )->status_is(200);
    my $url = submit( $t, target_occurrence_id => $to->id );
    like $url, qr{/pay\z}, 'the walk stops at the payment page';
    return ( $t, run_of($url) );
}

subtest 'customer changes entitlement through workflow' => sub {
    my ( $version, $from, $to ) = occurrences( 0, 4, 72, 96 );
    my $holder = member('parent');
    my $e      = booking( $version, $from, $holder );

    my $t = client($holder);
    $t->get_ok('/entitlement-change')->status_is(200);
    ok form_of($t)->at( 'input[name="entitlement_id"][value="' . $e->id . '"]' ), 'the holder is offered their booking';
    like submit( $t, entitlement_id => $e->id ), qr{/hold-target\z}, 'on to the occurrences';
    ok form_of($t)->at( 'input[name="target_occurrence_id"][value="' . $to->id . '"]' ), 'the other occurrence is offered';
    like submit( $t, target_occurrence_id => $to->id ), qr{/complete-change\z},
        'with no fee the payment page is skipped';
    like submit($t), qr{/done\z}, 'completing lands on the done page';

    is_deeply $e->units( $db, $to->id ), [1], 'the customer holds the target occurrence';
    is_deeply $e->units( $db, $from->id ), [], 'and not the old one';
};

subtest 'entitlement-change admits parent admin and staff and refuses an anonymous visitor' => sub {
    client( member($_) )->get_ok('/entitlement-change')->status_is( 200, "a $_ reaches the workflow" )
        for qw( parent admin staff );
    my $before = runs();
    client()->get_ok('/entitlement-change')->status_is(302);
    is runs(), $before, 'an anonymous visitor creates no run';
};

subtest 'a change with a fee stops at the payment page with the seat held' => sub {
    my ( $version, $from, $to ) = occurrences( 1000, 4, 72, 96 );
    my $holder = member('parent');
    my ( $t, $run ) = to_payment( $holder, booking( $version, $from, $holder ), $to );
    $t->content_like( qr/\$10\.00/, 'the fee is shown' );
    is holds_on($to), 1, 'the target seat is held';
    ok form_of($t), 'with a form to pay';
};

subtest 'an admin changes a customer\'s entitlement for them' => sub {
    my ( $version, $from, $to ) = occurrences( 0, 4, 72, 96 );
    my $e = booking( $version, $from, member('parent') );
    my $t = client( member('admin') );
    $t->get_ok( '/entitlement-change?entitlement_id=' . $e->id )->status_is(200);
    like submit( $t, target_occurrence_id => $to->id ), qr{/complete-change\z}, 'the admin holds the target';
    submit($t);
    is_deeply $e->units( $db, $to->id ), [1], 'the customer holds the target occurrence';
};

subtest 'stranger cannot change entitlement' => sub {
    my ( $version, $from, $to ) = occurrences( 1000, 4, 72, 96 );
    my $holder = member('parent');
    my $e      = booking( $version, $from, $holder );

    my $t = client( member('parent') );
    $t->get_ok( '/entitlement-change?entitlement_id=' . $e->id )->status_is(200);
    my $action = form_of($t)->attr('action');
    like $action, qr{/choose-target\z}, 'a link to someone else\'s booking does not get past choosing';
    $t->post_ok( $action => form => { entitlement_id => $e->id } )->status_is(302);
    $t->get_ok( $t->tx->res->headers->location )->content_like(qr/not yours/i, 'posting it is refused');
    ok !run_of($action)->data->{change_entitlement_id}, 'the run names no booking to change';
    is holds_on($to), 0, 'no hold is placed';

    # Nor can they drive the holder's own run, at the hold or the charge.
    my $own = client($holder);
    $own->get_ok( '/entitlement-change?entitlement_id=' . $e->id )->status_is(200);
    my $hold_url = form_of($own)->attr('action');
    my $other    = client( member('parent') );
    $other->post_ok( $hold_url => form => { target_occurrence_id => $to->id } );
    is holds_on($to), 0, 'posting to the holder\'s run holds nothing';

    my ( undef, $run ) = to_payment( $holder, $e, $to );
    $other->post_ok( '/entitlement-change/' . $run->id . '/pay' => form => {} );
    is payments_of($run), 0, 'and posting its payment page starts no payment';

    # Nor complete a zero-fee change the holder has held but not confirmed.
    my ( $free, $free_from, $free_to ) = occurrences( 0, 4, 72, 96 );
    my $free_e = booking( $free, $free_from, $holder );
    my $mine   = client($holder);
    $mine->get_ok( '/entitlement-change?entitlement_id=' . $free_e->id )->status_is(200);
    my $complete = submit( $mine, target_occurrence_id => $free_to->id );
    like $complete, qr{/complete-change\z}, 'the holder reaches the confirmation';
    $other->post_ok( $complete => form => {} );
    is_deeply $free_e->units( $db, $free_to->id ), [], 'posting the holder\'s confirmation moves nothing';
    is_deeply $free_e->units( $db, $free_from->id ), [1], 'the booking stays where it was';
};

subtest 'unauthenticated visitor sent to sign in' => sub {
    my ( $version, $from, $to ) = occurrences( 0, 4, 72, 96 );
    my $e = booking( $version, $from, member('parent') );
    my $t = client();
    $t->get_ok( '/entitlement-change?entitlement_id=' . $e->id )->status_is(302)
        ->header_like( Location => qr{/auth/login} );
    is holds_on($to), 0, 'no hold is placed';
};

subtest 'other tenant entitlement not found' => sub {
    my $slug  = "ec_other_$$";
    my $owner = member('admin');
    Registry::DAO::Tenant->provision( $db, { name => "EC Other $$", slug => $slug, users => [$owner] } );
    my $other = $dao->connect_schema($slug)->db;
    my $room  = $other->insert( 'locations', { name => 'Far room', slug => 'far-room' }, { returning => 'id' } )->hash->{id};
    my $class = $other->insert( 'projects', { name => 'Far class', slug => 'far-class' }, { returning => 'id' } )->hash->{id};
    my $teach = $other->insert( 'users', { username => "ec-far-$$" }, { returning => 'id' } )->hash->{id};
    my @res = map {
        Registry::DAO::Resource->for_occurrence( $other, $other->insert( 'events', {
            project_id => $class, location_id => $room, teacher_id => $teach,
            time => \"now() + interval '$_ hours'", duration => 90, capacity => 4 }, { returning => 'id' } )->hash->{id} )
    } 72, 96;
    my $version = Registry::DAO::Offer->create( $other, { name => 'Far wheel' } )
        ->draft( $other, offer_terms( undef, class_project_id => $class, policies => {
            refund => { kind => 'none' },
            change => { kind => 'window', window_hours => 48, fee_cents => 0, targets => 'same_offer' },
            expiry => { kind => 'end_of_occurrence' } } ) )->publish($other);
    my $e = Registry::DAO::Entitlement->grant( $other, {
        holder_user_id => $teach, offer_version_id => $version->id, payment_plan_id => 'pay',
        starts_at => '2020-01-01T00:00:00Z', resource_id => $res[0]->id, units => 1 } );

    my $t = client( member('admin') );
    $t->get_ok( '/entitlement-change?entitlement_id=' . $e->id )->status_is(200);
    my $action = form_of($t)->attr('action');
    $t->post_ok( $action => form => { entitlement_id => $e->id } )->status_is(302);
    $t->get_ok( $t->tx->res->headers->location )->content_like(qr/Choose a booking to change/);
    ok !run_of($action)->data->{change_entitlement_id}, 'the other tenant\'s booking is not found';
    is holds_on( $res[1] ), 0, 'no hold is placed in the other tenant';
    my $live = Registry::PriceOps::Hold->live_sql('holds');
    is $db->query( "SELECT count(*) FROM holds WHERE workflow_run_id = ? AND $live", run_of($action)->id )->array->[0],
        0, 'nor in this one';
};

subtest 'hold or complete without target refused' => sub {
    my ( $version, $from, $to ) = occurrences( 0, 4, 72, 96 );
    my $holder = member('parent');
    my $e      = booking( $version, $from, $holder );
    my $t      = client($holder);
    $t->get_ok('/entitlement-change')->status_is(200);
    my $run = run_of( form_of($t)->attr('action') );
    for my $step (qw( hold-target complete-change )) {
        $t->post_ok( "/entitlement-change/${\ $run->id }/$step" => form => { target_occurrence_id => $to->id } );
        isnt $t->tx->res->code, 200, "posting $step first is refused";
        unlike $t->tx->res->headers->location // '', qr{/(?:pay|complete-change|done)\z}, "$step does not move the run on";
    }
    is holds_on($to), 0, 'no hold is placed';
    is_deeply $e->units( $db, $from->id ), [1], 'and the booking stays where it was';
};

subtest 'abandoned walk frees seat after hold lapses' => sub {
    my ( $version, $from, $to ) = occurrences( 1000, 1, 72, 96 );
    my $first = member('parent');
    my ( undef, $run ) = to_payment( $first, booking( $version, $from, $first ), $to );

    my $second = member('parent');
    my $e      = booking( $version, booking_room( $version, $from ), $second );
    my $t      = client($second);
    $t->get_ok( '/entitlement-change?entitlement_id=' . $e->id )->status_is(200);
    ok !form_of($t)->at( 'input[name="target_occurrence_id"][value="' . $to->id . '"]' ),
        'while the first walk holds it, the seat is not offered';

    $db->query( q{UPDATE holds SET expires_at = clock_timestamp() - interval '1 second' WHERE workflow_run_id = ?},
        $run->id );
    my $again = client($second);
    $again->get_ok( '/entitlement-change?entitlement_id=' . $e->id )->status_is(200);
    like submit( $again, target_occurrence_id => $to->id ), qr{/pay\z},
        'once the hold lapses another customer holds the seat';
};

# Another occurrence of $version's class, with a free seat, for a second booking.
sub booking_room ( $version, $like ) {
    my $event = $db->select( 'events', '*', { id => $like->event_id } )->hash;
    my $id = $db->insert( 'events', { %$event{qw( project_id location_id teacher_id duration )},
        time => \"now() + interval '80 hours'", capacity => 4 }, { returning => 'id' } )->hash->{id};
    return Registry::DAO::Resource->for_occurrence( $db, $id );
}

subtest 'resubmitted payment page creates no second payment' => sub {
    my ( $version, $from, $to ) = occurrences( 1000, 4, 72, 96 );
    my $holder = member('parent');
    my ( $t, $run ) = to_payment( $holder, booking( $version, $from, $holder ), $to );

    # The first submit started the fee payment and Stripe answered with an intent.
    $run->update_data( $db, { user_id => $holder->id } );
    my $pay_step = Registry::DAO::Workflow->find( $db, { slug => 'entitlement-change' } )
        ->get_step( $db, { slug => 'pay' } );
    my $first = $pay_step->owed_payment( $db, $run )->{payment} or return fail 'the first submit started a payment';
    $first->_record_intent( $db, { id => 'pi_ec_' . $first->id, client_secret => 'x_secret' } );

    local $ENV{STRIPE_SECRET_KEY};    # no Stripe here: the resubmit's intent call fails after the payment is chosen
    $t->post_ok( form_of($t)->attr('action') => form => {} );
    is payments_of($run), 1, 'the resubmit reuses the payment the first submit started';
};

subtest 'paid change with no seat left shows a friendly page' => sub {
    my ( $version, $from, $to ) = occurrences( 1000, 1, 72, 96 );
    my $holder = member('parent');
    my $e      = booking( $version, $from, $holder );
    my ( $t, $run ) = to_payment( $holder, $e, $to );
    {
        local $ENV{STRIPE_SECRET_KEY};
        $t->post_ok( form_of($t)->attr('action') => form => {} );
    }
    my $payment = Registry::DAO::Payment->find( $db,
        { id => Registry::DAO::WorkflowRun->find( $db, { id => $run->id } )->data->{owed_payment_id} } );
    $payment->_record_intent( $db, { id => 'pi_ec_' . $payment->id, client_secret => 'x_secret' } );
    $payment->mark_completed( $db, $payment->stripe_payment_intent_id ) or die 'not completed';

    # The hold lapses and the seat is sold before the person comes back.
    $db->query( q{UPDATE holds SET expires_at = clock_timestamp() - interval '1 second' WHERE workflow_run_id = ?},
        $run->id );
    booking( $version, $to, member('parent') );

    $t->get_ok( '/entitlement-change/' . $run->id . '/pay' )->status_is(200);
    like submit($t), qr{/complete-change\z}, 'the paid fee moves the run on';
    my $form = form_of($t);
    $t->post_ok( $form->attr('action') => form => {} )->status_is(302);
    $t->get_ok( $t->tx->res->headers->location )->status_is(200)
        ->content_like( qr/fee is paid/i, 'the person is told their fee is paid' )
        ->content_like( qr/studio/i, 'and that the studio will sort it out' );
    is_deeply $e->units( $db, $from->id ), [1], 'the booking stays where it was';
};

done_testing;
