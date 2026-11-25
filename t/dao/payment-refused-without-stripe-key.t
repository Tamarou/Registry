#!/usr/bin/env perl
# ABOUTME: A priced payment is refused when the Stripe key or the selling tenant's account is missing.
# ABOUTME: Covers the after-school Payment step and OneTimePayment; only a $0 cart completes without Stripe.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::PricingProbe qw( give_tenant_terms );
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Family;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Location;
use Registry::DAO::Offer;
use Registry::DAO::Resource;
use Registry::DAO::WorkflowSteps::Payment;
use Registry::PriceOps::Hold;
use Test::Registry::Async qw( settle );

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;

my $UNAVAILABLE = Registry::DAO::WorkflowSteps::Payment->payment_unavailable_message;

# A tenant schema, Stripe Connect ready unless told otherwise.
my $tenants = 0;
sub tenant (%opt) {
    my $n    = ++$tenants;
    my $slug = "nokey_${n}_$$";
    my $admin = Registry::DAO::User->create( $db, {
        username => "nokey_admin_${n}_$$", email => "nokey_admin_${n}_$$\@test.example",
        name => "No Key Admin $n", user_type => 'admin' } );
    Registry::DAO::Tenant->provision( $db, {
        name => "No Key $n $$", slug => $slug, users => [$admin],
        ( $opt{no_account} ? () : ( stripe_connect_account_id => "acct_nokey_${n}_$$",
            stripe_charges_enabled => 1, stripe_details_submitted => 1 ) ) } );
    give_tenant_terms( $db, $slug, { rate => '0.025' } );
    return { slug => $slug, db => Registry::DAO->new( url => $test_db->uri, schema => $slug )->db };
}

# ---- the after-school Payment step ----------------------------------------

# A session priced by $plans (pricing plan args), a parent and child, and a
# workflow whose first step is Payment.
sub cart_tenant (%opt) {
    my $s   = tenant(%opt);
    my $tdb = $s->{db};
    my $location = Registry::DAO::Location->create( $tdb, {
        name => 'Loc', address_info => { street_address => '1 A', city => 'T', state => 'TS', postal_code => '12345' } } );
    my $teacher = Registry::DAO::User->create( $tdb, {
        name => 'Teacher', username => "tch_$s->{slug}", email => "tch_$s->{slug}\@test.example", user_type => 'staff' } );
    my $project = Registry::DAO::Project->create( $tdb, { name => 'Program', metadata => {} } );
    my $event   = Registry::DAO::Event->create( $tdb, {
        time => '2099-07-01 10:00:00', duration => 120, capacity => 20,
        location_id => $location->id, project_id => $project->id, teacher_id => $teacher->id } );

    my %session;
    for my $name ( keys %{ $opt{sessions} } ) {
        my $session = Registry::DAO::Session->create( $tdb, {
            name => $name, start_date => '2099-07-02', end_date => '2099-07-09', status => 'published' } );
        $session->add_events( $tdb, $event->id );
        Registry::DAO::PricingPlan->create( $tdb, { session_id => $session->id, plan_type => 'standard', %$_ } )
            for @{ $opt{sessions}{$name} };
        $session{$name} = $session;
    }

    my $parent = Registry::DAO::User->create( $tdb, {
        name => 'Parent', username => "par_$s->{slug}", email => "par_$s->{slug}\@test.example", user_type => 'parent' } );
    my $child = Registry::DAO::Family->add_child( $tdb, $parent->id, {
        child_name => 'Kid', birth_date => '2016-03-15', grade => '3',
        medical_info => {}, emergency_contact => { name => 'E', phone => '555-0123' } } );

    my $wf = Registry::DAO::Workflow->create( $tdb, {
        name => 'Pay', slug => "pay-$s->{slug}", description => 'payment refusal test' } );
    $wf->add_step( $tdb, { slug => 'payment', class => 'Registry::DAO::WorkflowSteps::Payment' } );
    $wf->update( $tdb, { first_step => 'payment' }, { id => $wf->id } );

    return { %$s, session => \%session, parent => $parent, child => $child, workflow => $wf };
}

# A run whose cart is the child in $session_name.
sub cart_run ( $s, $session_name ) {
    my $child_id   = $s->{child}->id;
    my $session_id = $s->{session}{$session_name}->id;
    my $run = $s->{workflow}->new_run( $s->{db} );
    $run->update_data( $s->{db}, {
        user_id            => $s->{parent}->id,
        __tenant_slug      => $s->{slug},
        children           => [ { id => $child_id, first_name => 'Kid', last_name => '', birth_date => '2016-03-15', grade => '3' } ],
        session_selections => { $child_id => $session_id },
        enrollment_items   => [ { child_id => $child_id, session_id => $session_id } ],
    } );
    return $run;
}

sub checkout ( $s, $run ) {
    my @warnings;
    my $out = do {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        settle( $s->{workflow}->get_step( $s->{db}, { slug => 'payment' } )
            ->process( $s->{db}, { agreeTerms => 1 }, $run ) );
    };
    return ( $out, "@warnings" );
}

sub rows_for_cart ($s) {
    my $q = sub ($sql) { $s->{db}->query( $sql, $s->{parent}->id )->array->[0] };
    return {
        enrollments => $s->{db}->query( 'SELECT count(*) FROM enrollments WHERE family_member_id = ?',
            $s->{child}->id )->array->[0],
        payments => $q->('SELECT count(*) FROM payments WHERE user_id = ?'),
        payment_items => $q->('SELECT count(*) FROM payment_items i JOIN payments p ON p.id = i.payment_id WHERE p.user_id = ?'),
    };
}

my $ready = cart_tenant( sessions => {
    Priced => [ { plan_name => 'Standard', amount_cents => 15000 } ],
    Free   => [ { plan_name => 'Free',     amount_cents => 0 } ],
} );

subtest 'priced cart without a stripe key is refused' => sub {
    local $ENV{STRIPE_SECRET_KEY};
    delete $ENV{STRIPE_SECRET_KEY};

    my ( $out, $warned ) = checkout( $ready, cart_run( $ready, 'Priced' ) );
    is_deeply $out->{errors}, [$UNAVAILABLE], 'refused with the unavailable message';
    isnt $out->{next_step}, 'complete', 'the run does not complete';
    like $warned, qr/checkout refused: STRIPE_SECRET_KEY is not set/, 'the refusal is logged';
    is_deeply rows_for_cart($ready), { enrollments => 0, payments => 0, payment_items => 0 },
        'nothing enrolled, no payment written';
};

my $unready = cart_tenant( no_account => 1, sessions => {
    Priced => [ { plan_name => 'Standard', amount_cents => 15000 } ],
    Free   => [ { plan_name => 'Free',     amount_cents => 0 } ],
} );

subtest '$0 cart without a stripe key completes' => sub {
    local $ENV{STRIPE_SECRET_KEY};
    delete $ENV{STRIPE_SECRET_KEY};

    my ( $out, $warned ) = checkout( $unready, cart_run( $unready, 'Free' ) );
    is $out->{next_step}, 'complete', 'the run completes';
    ok !$out->{errors}, 'with no error' or diag explain $out->{errors};
    is $warned, '', 'and nothing refused';
    is_deeply rows_for_cart($unready), { enrollments => 1, payments => 0, payment_items => 0 },
        'enrolled without a payment, on a tenant with no Stripe account';
    $unready->{db}->query( 'DELETE FROM enrollments WHERE family_member_id = ?', $unready->{child}->id );
};

subtest 'priced cart for a tenant not ready is refused even with a key' => sub {
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_placeholder_not_real';

    my ( $out, $warned ) = checkout( $unready, cart_run( $unready, 'Priced' ) );
    is_deeply $out->{errors}, [$UNAVAILABLE], 'refused with the unavailable message';
    like $warned, qr/checkout refused: tenant '\Q$unready->{slug}\E' is not Stripe Connect ready/,
        'the refusal names the tenant';
    is_deeply rows_for_cart($unready), { enrollments => 0, payments => 0, payment_items => 0 },
        'nothing enrolled, no payment written';
};

# ---- OneTimePayment --------------------------------------------------------

sub seller (%opt) {
    my $s = tenant(%opt);
    my $tdb = $s->{db};
    my $resource = Registry::DAO::Resource->create( $tdb, { name => 'Studio seat', kind => 'unbounded' } );
    my $version  = Registry::DAO::Offer->create( $tdb, { name => 'Drop-in' } )
        ->draft( $tdb, offer_terms( $resource->id ) )->publish($tdb);
    my $buyer = Registry::DAO::User->create( $tdb, {
        username => "buyer_$s->{slug}", email => "buyer_$s->{slug}\@test.example",
        name => 'Buyer', user_type => 'parent' } );
    my $wf = Registry::DAO::Workflow->create( $tdb, {
        name => 'OTP', slug => "otp-$s->{slug}", description => 'one-time payment refusal test' } );
    $wf->add_step( $tdb, { slug => $_->[0], class => $_->[1] } ) for
        [ before => 'Registry::DAO::WorkflowStep' ],
        [ pay    => 'Registry::DAO::WorkflowSteps::OneTimePayment' ],
        [ after  => 'Registry::DAO::WorkflowStep' ];
    return { %$s, version => $version, buyer => $buyer, workflow => $wf };
}

sub owed_run ($s) {
    my $run = $s->{workflow}->new_run( $s->{db}, {} );
    $run->process( $s->{db}, $s->{workflow}->first_step( $s->{db} ), {} );
    $run->update_data( $s->{db}, {
        user_id       => $s->{buyer}->id,
        __tenant_slug => $s->{slug},
        owed_payment  => { offer_version_id => $s->{version}->id, payment_plan => 'pay',
                           amount_cents => 1060, description => 'Seat' },
    } );
    return $run;
}

sub pay ( $s, $run ) {
    my @warnings;
    my $out = do {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        settle( $s->{workflow}->get_step( $s->{db}, { slug => 'pay' } )->process( $s->{db}, {}, $run ) );
    };
    return ( $out, "@warnings" );
}

sub rows_for_buyer ($s) {
    my $q = sub ($sql) { $s->{db}->query( $sql, $s->{buyer}->id )->array->[0] };
    return {
        payments     => $q->('SELECT count(*) FROM payments WHERE user_id = ?'),
        entitlements => $q->('SELECT count(*) FROM entitlements WHERE holder_user_id = ?'),
    };
}

my $studio = seller();

subtest 'one time payment without a stripe key is refused' => sub {
    local $ENV{STRIPE_SECRET_KEY};
    delete $ENV{STRIPE_SECRET_KEY};

    my ( $out, $warned ) = pay( $studio, owed_run($studio) );
    is_deeply $out->{errors}, ['This payment cannot be taken right now. Nothing has been charged.'],
        'refused with the unavailable message';
    like $warned, qr/one-time payment refused: STRIPE_SECRET_KEY is not set/, 'the refusal is logged';
    is_deeply rows_for_buyer($studio), { payments => 0, entitlements => 0 }, 'no payment, no entitlement';
};

my $unready_studio = seller( no_account => 1 );

subtest 'one time payment for a tenant not ready is refused even with a key' => sub {
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_placeholder_not_real';

    my ( $out, $warned ) = pay( $unready_studio, owed_run($unready_studio) );
    is_deeply $out->{errors}, ['This payment cannot be taken right now. Nothing has been charged.'],
        'refused with the unavailable message';
    like $warned, qr/one-time payment refused: tenant '\Q$unready_studio->{slug}\E' is not Stripe Connect ready/,
        'the refusal names the tenant';
    is_deeply rows_for_buyer($unready_studio), { payments => 0, entitlements => 0 }, 'no payment, no entitlement';
};

# ---- negative scenarios ----------------------------------------------------

my $UNPRICED = 'This registration could not be priced, so it cannot be completed. Nothing has been charged.';

my $odd = cart_tenant( sessions => {
    # The only plan needs three children; a cart of one resolves no price.
    Unpriced => [ { plan_name => 'Big Family Only', amount_cents => 30000,
                    requirements => { min_children => 3 } } ],
    Negative => [ { plan_name => 'Over-discounted', amount_cents => 10000,
                    requirements => { percentage_discount => 150 } } ],
} );

subtest 'undefined total refused not free' => sub {
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_placeholder_not_real';

    my ( $out, $warned ) = checkout( $odd, cart_run( $odd, 'Unpriced' ) );
    is_deeply $out->{errors}, [$UNPRICED], 'a cart with no resolved price is refused';
    like $warned, qr/checkout refused: the cart for run \S+ could not be priced/, 'and logged';

    # A child being enrolled who is missing from the priced cart altogether.
    my $run = cart_run( $odd, 'Unpriced' );
    $run->update_data( $odd->{db}, { children => [], session_selections => {} } );
    ( $out ) = checkout( $odd, $run );
    is_deeply $out->{errors}, [$UNPRICED], 'a child enrolled with no price line is refused';

    is_deeply rows_for_cart($odd), { enrollments => 0, payments => 0, payment_items => 0 },
        'nothing enrolled, no payment written';
};

subtest 'negative or non numeric total refused' => sub {
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_placeholder_not_real';

    my ( $out ) = checkout( $odd, cart_run( $odd, 'Negative' ) );
    is_deeply $out->{errors}, [$UNPRICED], 'a negative total is refused';
    is_deeply rows_for_cart($odd), { enrollments => 0, payments => 0, payment_items => 0 },
        'nothing enrolled, no payment written';

    my $step = 'Registry::DAO::WorkflowSteps::Payment';
    for my $total ( 'abc', '12.5', '', ' 100', '1e3', [], undef ) {
        is $step->unpriced_cart_refusal( { total => $total, items => [] }, [] ), $UNPRICED,
            'total ' . ( defined $total ? "'$total'" : 'undef' ) . ' is refused';
    }
    is $step->unpriced_cart_refusal( { total => 0, items => [] }, [] ), undef, 'a $0 total is priced';
};

subtest 'empty stripe key treated as missing' => sub {
    local $ENV{STRIPE_SECRET_KEY} = '';

    my ( $out, $warned ) = checkout( $ready, cart_run( $ready, 'Priced' ) );
    is_deeply $out->{errors}, [$UNAVAILABLE], 'a priced cart is refused';
    like $warned, qr/STRIPE_SECRET_KEY is not set/, 'as if no key were set';

    ( $out, $warned ) = pay( $studio, owed_run($studio) );
    is_deeply $out->{errors}, ['This payment cannot be taken right now. Nothing has been charged.'],
        'a one-time payment is refused';
    like $warned, qr/STRIPE_SECRET_KEY is not set/, 'as if no key were set';
};

subtest 'tenant without stripe account refused' => sub {
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_placeholder_not_real';
    is $db->query( 'SELECT stripe_connect_account_id FROM registry.tenants WHERE slug = ?',
        $unready->{slug} )->array->[0], undef, 'the tenant has no Stripe account id at all';

    # A Stripe call under the placeholder key would fail with a processing
    # error; the unavailable message and no row mean none was made.
    my ( $out ) = checkout( $unready, cart_run( $unready, 'Priced' ) );
    is_deeply $out->{errors}, [$UNAVAILABLE], 'a priced cart is refused before Stripe';
    ( $out ) = pay( $unready_studio, owed_run($unready_studio) );
    is_deeply $out->{errors}, ['This payment cannot be taken right now. Nothing has been charged.'],
        'a one-time payment is refused before Stripe';
    is rows_for_cart($unready)->{payments} + rows_for_buyer($unready_studio)->{payments}, 0, 'no payment row';
};

subtest 'refusal writes no payment or entitlement rows' => sub {
    local $ENV{STRIPE_SECRET_KEY};
    delete $ENV{STRIPE_SECRET_KEY};

    # A one-time payment for seats a live hold keeps.
    my $seats = Registry::DAO::Resource->create( $studio->{db},
        { name => 'Wheel seats', kind => 'finite', capacity => 4 } );
    my $run  = owed_run($studio);
    my $hold = Registry::PriceOps::Hold->place( $studio->{db}, {
        resource_id => $seats->id, units => 2, workflow_run_id => $run->id,
        expires_at  => \"now() + interval '15 minutes'" } );
    $run->update_data( $studio->{db}, { owed_payment => { %{ $run->data->{owed_payment} }, hold_id => $hold->id } } );

    my ( $out ) = pay( $studio, $run );
    ok $out->{errors}, 'the one-time payment is refused';
    is $studio->{db}->query( 'SELECT state FROM holds WHERE id = ?', $hold->id )->array->[0], 'held',
        'the hold is not converted as paid';
    is_deeply rows_for_buyer($studio), { payments => 0, entitlements => 0 }, 'no payment, no entitlement';
    is $studio->{db}->query( q{SELECT count(*) FROM payments WHERE metadata->>'stripe_customer_id' IS NOT NULL} )->array->[0],
        0, 'no Stripe customer recorded';

    ( $out ) = checkout( $ready, cart_run( $ready, 'Priced' ) );
    ok $out->{errors}, 'the priced cart is refused';
    is_deeply rows_for_cart($ready), { enrollments => 0, payments => 0, payment_items => 0 },
        'no enrollment, payment or line item';
};

subtest 'refusal message leaks no secret' => sub {
    my $secret = 'sk_test_LEAKCHECK0123456789';
    local $ENV{STRIPE_SECRET_KEY} = $secret;

    for my $case (
        [ 'unready tenant cart', sub { checkout( $unready, cart_run( $unready, 'Priced' ) ) } ],
        [ 'unready tenant one-time', sub { pay( $unready_studio, owed_run($unready_studio) ) } ],
        [ 'unpriced cart', sub { checkout( $odd, cart_run( $odd, 'Unpriced' ) ) } ],
    ) {
        my ( $name, $go ) = @$case;
        my ( $out, $warned ) = $go->();
        my $shown = join "\n", @{ $out->{errors} || [] };
        ok length $shown, "$name: refused";
        unlike $shown, qr/\Q$secret\E/, "$name: the message holds no key";
        unlike $shown, qr/ at \S+ line \d+|STRIPE_SECRET_KEY/, "$name: nor a stack trace or variable name";
        unlike $warned, qr/\Q$secret\E/, "$name: nor does the log";
    }
};

$test_db->cleanup_test_database;
done_testing;
