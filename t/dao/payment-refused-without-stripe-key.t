#!/usr/bin/env perl
# ABOUTME: A priced payment is refused when the Stripe key or the selling tenant's account is missing.
# ABOUTME: Covers the session cart's payment step and OneTimePayment; nothing is written when either refuses.
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
use Registry::DAO::FamilyMember;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::Offer;
use Registry::DAO::Resource;
use Test::Registry::Helpers qw( days_from_now );
use Test::Registry::Sessions qw( make_session session_offer held_cart );
use Registry::PriceOps::Hold;
use Test::Registry::Async qw( settle );

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;

my $UNAVAILABLE = 'This payment cannot be taken right now. Nothing has been charged.';

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

# ---- the session cart's payment step --------------------------------------

# A session sold at $150, a parent and child, all in the tenant's schema.
sub cart_tenant (%opt) {
    my $s      = tenant(%opt);
    my $tdao   = Registry::DAO->new( url => $test_db->uri, schema => $s->{slug} );
    my $parent = Registry::DAO::User->create( $s->{db}, {
        name => 'Parent', username => "par_$s->{slug}", email => "par_$s->{slug}\@test.example", user_type => 'parent' } );
    my $child = Registry::DAO::FamilyMember->create( $s->{db}, {
        family_id => $parent->id, child_name => 'Kid', birth_date => '2016-03-15' } );
    return { %$s, dao => $tdao, parent => $parent, child => $child };
}

# A cart of the child in a new session, held and owing, and its payment step.
sub cart_run ($s) {
    my $session = make_session( $s->{db}, days => [ map { days_from_now($_) } 30 .. 32 ] );
    my $version = session_offer( $s->{db}, $session, price_cents => 15000 );
    my ( $run, $pay ) = held_cart( $s->{dao}, $s->{parent}->id, [ $s->{child}->id, $session->id, $version->id, 'pay' ] );
    $s->{pay} = $pay;
    return $run;
}

sub checkout ( $s, $run ) {
    my @warnings;
    my $out = do {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        settle( $s->{pay}->process( $s->{db}, {}, $run ) );
    };
    return ( $out, "@warnings" );
}

sub rows_for_cart ($s) {
    my $q = sub ($sql) { $s->{db}->query( $sql, $s->{parent}->id )->array->[0] };
    return {
        entitlements => $q->('SELECT count(*) FROM entitlements WHERE payer_user_id = ?'),
        payments     => $q->('SELECT count(*) FROM payments WHERE user_id = ?'),
    };
}

my $ready = cart_tenant();

subtest 'priced cart without a stripe key is refused' => sub {
    local $ENV{STRIPE_SECRET_KEY};
    delete $ENV{STRIPE_SECRET_KEY};

    my ( $out, $warned ) = checkout( $ready, cart_run($ready) );
    is_deeply $out->{errors}, [$UNAVAILABLE], 'refused with the unavailable message';
    like $warned, qr/payment refused: STRIPE_SECRET_KEY is not set/, 'the refusal is logged';
    is_deeply rows_for_cart($ready), { entitlements => 0, payments => 0 }, 'nothing booked, no payment written';
};

my $unready = cart_tenant( no_account => 1 );

subtest 'priced cart for a tenant not ready is refused even with a key' => sub {
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_placeholder_not_real';

    my ( $out, $warned ) = checkout( $unready, cart_run($unready) );
    is_deeply $out->{errors}, [$UNAVAILABLE], 'refused with the unavailable message';
    like $warned, qr/payment refused: tenant '\Q$unready->{slug}\E' is not Stripe Connect ready/,
        'the refusal names the tenant';
    is_deeply rows_for_cart($unready), { entitlements => 0, payments => 0 }, 'nothing booked, no payment written';
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

subtest 'a share that is not whole cents above zero is refused' => sub {
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_placeholder_not_real';

    for my $share ( -100, 0, 'abc', '12.5', '', ' 100', '1e3', [], undef ) {
        my $run  = cart_run($ready);
        my $owed = $run->data->{owed_payment};
        $owed->{lines}[0]{share_cents} = $share;
        $owed->{amount_cents} = $share if !ref $share && defined $share && $share =~ /\A-?[0-9]+\z/;
        $run->update_data( $ready->{db}, { owed_payment => $owed } );
        my ( $out ) = checkout( $ready, $run );
        ok $out->{errors}, 'share ' . ( defined $share ? "'$share'" : 'undef' ) . ' is refused';
    }
    is_deeply rows_for_cart($ready), { entitlements => 0, payments => 0 }, 'nothing booked, no payment written';
};

subtest 'empty stripe key treated as missing' => sub {
    local $ENV{STRIPE_SECRET_KEY} = '';

    my ( $out, $warned ) = checkout( $ready, cart_run($ready) );
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
    my ( $out ) = checkout( $unready, cart_run($unready) );
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

    my $cart = cart_run($ready);
    ( $out ) = checkout( $ready, $cart );
    ok $out->{errors}, 'the priced cart is refused';
    is_deeply rows_for_cart($ready), { entitlements => 0, payments => 0 }, 'no entitlement or payment';
    is $ready->{db}->query( q{SELECT count(*) FROM holds WHERE workflow_run_id = ? AND state = 'held'}, $cart->id )
        ->array->[0], 1, "the child's seat stays held, not converted as paid";
};

subtest 'refusal message leaks no secret' => sub {
    my $secret = 'sk_test_LEAKCHECK0123456789';
    local $ENV{STRIPE_SECRET_KEY} = $secret;

    for my $case (
        [ 'unready tenant cart', sub { checkout( $unready, cart_run($unready) ) } ],
        [ 'unready tenant one-time', sub { pay( $unready_studio, owed_run($unready_studio) ) } ],
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
