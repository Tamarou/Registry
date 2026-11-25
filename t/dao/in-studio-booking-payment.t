#!/usr/bin/env perl
# ABOUTME: Paying for an in-studio booking: a direct charge on the studio's account, completed by CompleteBooking.
# ABOUTME: A signed Connect payment_intent.succeeded turns the hold into the booker's entitlement, linked to its payment.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::Helpers qw( import_all_workflows );
use Test::Registry::PricingProbe qw( give_tenant_terms );
use Test::Registry::Offers qw( offer_terms );
use Test::Registry::StripeWebhook;
use Test::Registry::Async qw( settle );

use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::DAO::Payment;
use Registry::DAO::Offer;
use Registry::DAO::Project;
use Registry::DAO::Resource;
use Registry::DAO::Entitlement;
use Registry::PriceOps::Hold;
use Registry::PriceOps::PlatformTerms qw( platform_terms_for_tenant );
use Registry::Utility::WorkflowProcessor;
use Registry::Terms;

local $ENV{STRIPE_WEBHOOK_SECRET}         = 'whsec_local_booking_payment';
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_local_booking_payment_connect';
# A priced payment is refused without a key; no Stripe call is made in this file.
local $ENV{STRIPE_SECRET_KEY} = 'sk_test_placeholder_booking_payment';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
import_all_workflows($dao);

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub ( $c, $tenant = undef ) {
    defined $tenant ? Registry::DAO->new( url => $test_db->uri, schema => $tenant ) : $dao } );
my $minion = $t->app->minion;

my %AGREE = ( agree_to_terms => 1, terms_version_shown => Registry::Terms::VERSION );

# A studio: a tenant with a Stripe account, Solo's 2.5% from the platform
# (unless no_terms), the booking workflow, a room, a teacher and a booker.
my $studios = 0;
sub studio (%opt) {
    my $n       = ++$studios;
    my $slug    = "isbp_${n}_$$";
    my $account = "acct_isbp_${n}_$$";
    my $admin   = Registry::DAO::User->create( $db, {
        username => "isbp_admin_${n}_$$", email => "isbp_admin_${n}_$$\@test.example",
        name => "ISBP Admin $n", user_type => 'admin' } );
    Registry::DAO::Tenant->provision( $db, {
        name => "ISBP $n $$", slug => $slug, users => [$admin],
        stripe_connect_account_id => $account, stripe_charges_enabled => 1, stripe_details_submitted => 1 } );
    give_tenant_terms( $db, $slug, { rate => '0.025' } ) unless $opt{no_terms};
    my $tdao = Registry::DAO->new( url => $test_db->uri, schema => $slug );
    import_all_workflows($tdao);
    my $tdb = $tdao->db;
    my $room = $tdb->insert( 'locations',
        { name => "Room $n", slug => "room-$n", time_zone => 'America/New_York' }, { returning => 'id' } )->hash->{id};
    my %user = map {
        $_ => Registry::DAO::User->create( $tdb, {
            username => "isbp_${_}_${n}_$$", email => "isbp_${_}_${n}_$$\@test.example",
            name => "ISBP \u$_ $n", user_type => $_ eq 'teacher' ? 'staff' : 'parent' } )
    } qw( booker teacher other );
    my $admin_in_studio = $tdb->select( 'users', 'id', { username => "isbp_admin_${n}_$$" } )->array;
    return {
        slug => $slug, account => $account, dao => $tdao, db => $tdb, room => $room, %user,
        admin    => $admin_in_studio && $admin_in_studio->[0],
        workflow => $tdao->find( Workflow => { slug => 'in-studio-booking' } ),
    };
}

# A class with one published occurrence a week out, of $seats seats, and a
# published one-time offer for it: $price_cents for $units seats, SACP's policies.
sub class_offer ( $s, %terms ) {
    state $n = 0;
    ++$n;
    my $seats = delete $terms{seats} // 6;
    my $class = Registry::DAO::Project->create( $s->{db},
        { name => "Throwing $n", seats_per_occurrence => $seats, metadata => { location_id => $s->{room} } } );
    my $event = $s->{db}->query( q{
        INSERT INTO events (project_id, location_id, teacher_id, time, duration, capacity, status)
        VALUES (?, ?, ?, now() + interval '7 days', 90, ?, 'published') RETURNING id
    }, $class->id, $s->{room}, $s->{teacher}->id, $seats )->array->[0];
    my $version = Registry::DAO::Offer->create( $s->{db}, { name => "Wheel $n" } )
        ->draft( $s->{db}, offer_terms( undef, class_project_id => $class->id, per_booking_cap => 4,
            price_cents => 4500,
            policies => {
                refund => { kind => 'none' },
                change => { kind => 'window', window_hours => 48, fee_cents => 1000, targets => 'same_offer' },
                use    => { kind => 'optional_attendance' },
                expiry => { kind => 'end_of_occurrence' },
            }, %terms ) )
        ->publish( $s->{db} );
    return ( $version, Registry::DAO::Resource->for_occurrence( $s->{db}, $event ) );
}

sub step ( $s, $slug ) { $s->{workflow}->get_step( $s->{db}, { slug => $slug } ) }

sub reload ( $s, $run ) { Registry::DAO::WorkflowRun->find( $s->{db}, { id => $run->id } ) }

# A run that chose $count of $version in $occurrence, agreed to the terms,
# signed in as the booker, and holds the seats: parked at payment.
sub held ( $s, $occurrence, $version, $count ) {
    my $u   = $s->{booker};
    my $run = Registry::WorkflowProcessor->new( dao => $s->{dao} )->new_run( $s->{workflow},
        { user => { id => $u->id, name => $u->name }, user_id => $u->id, __tenant_slug => $s->{slug} } );
    my @steps = (
        [ occurrence => { occurrence_id => $occurrence->id } ],
        [ offer      => { offer_version_id => $version->id, count => $count, %AGREE } ],
        [ account    => { action => 'continue_logged_in' } ],
        [ hold       => {} ],
    );
    for (@steps) {
        my $r = $run->process( $s->{db}, step( $s, $_->[0] ), $_->[1] );
        die "$_->[0] refused: @{ $r->{errors} }" if ref $r eq 'HASH' && $r->{errors};
    }
    return reload( $s, $run );
}

# The payment step's row for the run, with the intent Stripe answered
# recorded, as OneTimePayment starts it; no Stripe call is made.
sub started ( $s, $run ) {
    my $owed = step( $s, 'payment' )->owed_payment( $s->{db}, $run );
    die 'payment refused: ' . explain $owed->{errors} if $owed->{errors};
    my $payment = $owed->{payment};
    $payment->_record_intent( $s->{db}, { id => 'pi_isbp_' . $payment->id, client_secret => 'x_secret' } );
    return Registry::DAO::Payment->find( $s->{db}, { id => $payment->id } );
}

# payment_intent.succeeded on the Connect endpoint for $payment, as Stripe
# sends it for the studio's account; %over replaces parts of the event.
sub succeeded ( $s, $payment, %over ) {
    my $amount = exists $over{amount} ? delete $over{amount} : $payment->amount_cents;
    return Test::Registry::StripeWebhook::post_connect( $t, {
        type    => 'payment_intent.succeeded',
        account => $s->{account},
        data    => { object => {
            id                     => $payment->stripe_payment_intent_id,
            amount                 => $amount,
            application_fee_amount => Registry::DAO::Payment::application_fee_cents( $amount, '0.025' ),
            metadata               => { payment_id => $payment->id, tenant_slug => $s->{slug} },
        } },
        %over,
    } );
}

# Performs the queued run drivers, as Minion's worker would.
sub drive () {
    my $jobs = $minion->jobs( { tasks => ['continue_workflow_run'], states => ['inactive'] } );
    while ( my $job = $jobs->next ) { $minion->perform_jobs( { id => $job->{id} } ) }
}

sub entitlements_of ( $s, $payment ) {
    return [ Registry::DAO::Entitlement->created_by_payment( $s->{db}, $payment->id ) ];
}

my $sacp = studio();

subtest 'paid booking becomes entitlement holding its seats' => sub {
    my ( $version, $occurrence ) = class_offer( $sacp, units_per_acceptance => 2 );
    my $run     = held( $sacp, $occurrence, $version, 2 );
    my $hold_id = $run->data->{booking_hold}{hold_id};
    my $payment = started( $sacp, $run );
    is $payment->amount_cents, 9000, 'the charge is for 2 x the price';

    succeeded( $sacp, $payment )->status_is(200);
    drive();

    my ($e) = entitlements_of( $sacp, $payment )->@*;
    ok $e, 'an entitlement is created' or return;
    is $e->holder_user_id, $sacp->{booker}->id, 'held by the booker';
    is $e->offer_version_id, $version->id, 'stamped with the offer version';
    is $e->payment_plan_id, 'pay', 'and its one-time plan';
    is $e->state, 'active', 'active';
    is_deeply $e->units( $sacp->{db}, $occurrence->id ), [ 1 .. 4 ], 'holding 2 x 2 seats of the occurrence';
    is $occurrence->free_units( $sacp->{db} ), 2, 'leaving the other 2';
    is $sacp->{db}->select( 'holds', 'state', { id => $hold_id } )->array->[0], 'converted', 'the hold is converted';
    my ( undef, $ends ) = $occurrence->occurrence_window( $sacp->{db} );
    ok $sacp->{db}->query( 'SELECT upper(in_effect) = ?::timestamptz FROM entitlements WHERE id = ?', $ends, $e->id )
        ->array->[0], 'in effect until the occurrence ends';

    my $after = reload( $sacp, $run );
    ok $after->completed( $sacp->{db} ), 'the run is complete';
    is $after->latest_step( $sacp->{db} )->slug, 'done', 'at the done page';
    is Registry::DAO::Payment->find( $sacp->{db}, { id => $payment->id } )->platform_offer_version_id,
        platform_terms_for_tenant( $db, $sacp->{slug} )->{id}, "the payment carries the platform's offer version";
};

subtest 'booking entitlement links to its payment' => sub {
    my ( $version, $occurrence ) = class_offer($sacp);
    my $run     = held( $sacp, $occurrence, $version, 3 );
    my $payment = started( $sacp, $run );
    succeeded( $sacp, $payment )->status_is(200);
    drive();
    my ($e) = entitlements_of( $sacp, $payment )->@*;
    ok $e, 'the payment finds the entitlement it created' or return;
    is $e->payment_id, $payment->id, 'linked to its payment';
    is $e->payment_share_cents, 13500, 'with the whole charge as its share';
    # Set at insert: the database refuses a later repoint (t/dao/priceops-entitlement-lifecycle.t).
    ok !eval { $sacp->{db}->update( 'entitlements', { payment_id => undef }, { id => $e->id } ); 1 },
        'and the link cannot be cleared afterwards';
};

subtest 'booking entitlement records agreed terms version' => sub {
    my ( $version, $occurrence ) = class_offer($sacp);
    my $run     = held( $sacp, $occurrence, $version, 1 );
    my $payment = started( $sacp, $run );
    succeeded( $sacp, $payment )->status_is(200);
    drive();
    my ($e) = entitlements_of( $sacp, $payment )->@*;
    ok $e, 'the booking is made' or return;
    is $e->terms_version, Registry::Terms::VERSION, 'stamped with the /terms version the booker agreed to';
};

subtest 'booking without agreed terms not converted' => sub {
    my ( $version, $occurrence ) = class_offer($sacp);
    my $run     = held( $sacp, $occurrence, $version, 1 );
    my $payment = started( $sacp, $run );
    $sacp->{db}->query( q{UPDATE workflow_runs SET data = data - 'agreed_terms_version' WHERE id = ?}, $run->id );
    succeeded( $sacp, $payment )->status_is(200);
    drive();
    is_deeply entitlements_of( $sacp, $payment ), [], 'no entitlement is created';
    is $sacp->{db}->select( 'holds', 'state', { id => $run->data->{booking_hold}{hold_id} } )->array->[0], 'held',
        'the hold is not converted';
    ok !reload( $sacp, $run )->completed( $sacp->{db} ), 'and the run is not complete';
};

sub lapse ( $s, $run ) {
    $s->{db}->query( q{UPDATE holds SET expires_at = clock_timestamp() - interval '1 second'
                        WHERE workflow_run_id = ?}, $run->id );
}

sub hold_state ( $s, $id ) { $s->{db}->select( 'holds', 'state', { id => $id } )->array->[0] }

subtest 'failed payment releases hold and grants nothing' => sub {
    my ( $version, $occurrence ) = class_offer( $sacp, seats => 4 );
    my $run     = held( $sacp, $occurrence, $version, 2 );
    my $payment = started( $sacp, $run );
    Test::Registry::StripeWebhook::post_connect( $t, {
        type    => 'payment_intent.payment_failed',
        account => $sacp->{account},
        data    => { object => {
            id                 => $payment->stripe_payment_intent_id,
            amount             => $payment->amount_cents,
            last_payment_error => { message => 'Your card was declined.' },
            metadata           => { payment_id => $payment->id, tenant_slug => $sacp->{slug} },
        } },
    } )->status_is(200);
    drive();
    ok !reload( $sacp, $run )->completed( $sacp->{db} ), 'the run does not go on';
    ok $run->process( $sacp->{db}, step( $sacp, 'complete' ), {} )->{errors}, 'completing it is refused';
    is_deeply entitlements_of( $sacp, $payment ), [], 'no entitlement is created';
    is $occurrence->free_units( $sacp->{db} ), 2, 'the seats stay held while the booker may try another card';

    lapse( $sacp, $run );
    is $occurrence->free_units( $sacp->{db} ), 4, 'and are released when the hold lapses';
    ok $run->process( $sacp->{db}, step( $sacp, 'complete' ), {} )->{errors}, 'completing it is still refused';
    is_deeply entitlements_of( $sacp, $payment ), [], 'and no entitlement is created';
    is hold_state( $sacp, $run->data->{booking_hold}{hold_id} ), 'held', 'the lapsed hold is never converted';
};

subtest 'late payment after lapse retakes seats' => sub {
    my ( $version, $occurrence ) = class_offer( $sacp, seats => 4 );
    my $run     = held( $sacp, $occurrence, $version, 2 );
    my $first   = $run->data->{booking_hold}{hold_id};
    my $payment = started( $sacp, $run );
    lapse( $sacp, $run );
    succeeded( $sacp, $payment )->status_is(200);
    drive();

    my ($e) = entitlements_of( $sacp, $payment )->@*;
    ok $e, 'the seats still fit, so the booking is made' or return;
    is_deeply $e->units( $sacp->{db}, $occurrence->id ), [ 1, 2 ], 'holding the two seats';
    is hold_state( $sacp, $first ), 'released', 'the lapsed hold is released';
    my $again = reload( $sacp, $run )->data->{booking_hold}{hold_id};
    isnt $again, $first, 'the run names the hold taken again';
    is hold_state( $sacp, $again ), 'converted', 'which is converted';
    ok reload( $sacp, $run )->completed( $sacp->{db} ), 'the run is complete';
    is Registry::DAO::Payment->find( $sacp->{db}, { id => $payment->id } )->status, 'completed', 'nothing is refunded';
};

# Notifications to $user_id about $run.
sub told ( $s, $user_id, $run ) {
    return $s->{db}->query( q{SELECT subject, message FROM notifications
                               WHERE user_id = ? AND metadata->>'workflow_run_id' = ? ORDER BY created_at},
        $user_id, $run->id )->hashes->to_array;
}

subtest 'late payment with seats gone refunds and notifies' => sub {
    my ( $version, $occurrence ) = class_offer( $sacp, seats => 4 );
    my $run     = held( $sacp, $occurrence, $version, 2 );
    my $first   = $run->data->{booking_hold}{hold_id};
    my $payment = started( $sacp, $run );
    lapse( $sacp, $run );
    my $other = held( $sacp, $occurrence, $version, 3 );    # the seats sell while the hold is lapsed
    succeeded( $sacp, $payment )->status_is(200);
    {
        # No key: the refund is refused before any request reaches Stripe,
        # the same failure branch a Stripe error takes.
        local $ENV{STRIPE_SECRET_KEY} = '';
        drive();
    }

    is_deeply entitlements_of( $sacp, $payment ), [], 'no booking is made';
    is hold_state( $sacp, $first ), 'released', 'the lapsed hold is released';
    is $occurrence->free_units( $sacp->{db} ), 1, 'and the other booking keeps its seats';
    my $data = reload( $sacp, $run )->data;
    is_deeply $data->{booking_refund}, {
        payment_id      => $payment->id,
        amount_cents    => 9000,
        idempotency_key => 'refund:booking:' . $run->id,
    }, 'the run records the refund owed: the whole charge, under a key for the run';
    like $data->{__driver}{error}, qr/refund/, 'the failed refund is retried by the driver';
    like Registry::DAO::Payment->find( $sacp->{db}, { id => $payment->id } )->metadata->{refund_last_failure}{message},
        qr/STRIPE_SECRET_KEY/, 'and recorded on the payment';

    my $booker = told( $sacp, $sacp->{booker}->id, $run );
    is scalar @$booker, 1, 'the booker is told once';
    like $booker->[0]{message}, qr/\$90\.00.*refunded/s, 'that the payment is refunded';
    my $staff = told( $sacp, $sacp->{admin}, $run );
    is scalar @$staff, 1, 'and the studio admin once';
    like $staff->[0]{message}, qr/\Q${\ $payment->id }\E/, 'naming the payment';

    # Stripe answered the refund; asking again under its key sends nothing.
    Registry::DAO::Payment->find( $sacp->{db}, { id => $payment->id } )->_apply_refund_result( $sacp->{db},
        { id => 're_isbp_late', status => 'succeeded' }, 9000, 'requested_by_customer', 0, $data->{booking_refund}{idempotency_key} );
    my $again = settle( $run->process( $sacp->{db}, step( $sacp, 'complete' ), {} ) );
    like "@{ $again->{errors} // [] }", qr/refunded/, 'the booker is shown the refund';
    ok !$again->{retry}, 'with nothing left to retry';
    is Registry::DAO::Payment->find( $sacp->{db}, { id => $payment->id } )->status, 'refunded', 'the payment is refunded';
    is scalar told( $sacp, $sacp->{booker}->id, $run )->@*, 1, 'and nobody is told twice';
    is_deeply entitlements_of( $sacp, $payment ), [], 'and still no booking is made';
};

# The platform's admins: told of a charge Stripe took for the wrong amount.
my $platform_admin = Registry::DAO::User->create( $db, {
    username => "isbp_platform_$$", email => "isbp_platform_$$\@test.example",
    name => 'ISBP Platform', user_type => 'admin' } );

sub refund_jobs ($intent) {
    my $jobs = $minion->jobs( { tasks => ['superseded_refund'], notes => [$intent] } );
    my @jobs;
    while ( my $job = $jobs->next ) { push @jobs, $job }
    return \@jobs;
}

subtest 'paid amount differing from quote refunds and alerts' => sub {
    my ( $version, $occurrence ) = class_offer($sacp);
    my $run     = held( $sacp, $occurrence, $version, 2 );
    my $payment = started( $sacp, $run );
    my $intent  = $payment->stripe_payment_intent_id;
    succeeded( $sacp, $payment, amount => 4500 )->status_is( 200, 'acknowledged, not retried' );
    drive();

    is_deeply entitlements_of( $sacp, $payment ), [], 'no booking is made';
    my $row = Registry::DAO::Payment->find( $sacp->{db}, { id => $payment->id } );
    is $row->status, 'failed', 'the payment is not completed';
    ok !reload( $sacp, $run )->completed( $sacp->{db} ), 'and the run does not go on';

    my $jobs = refund_jobs($intent);
    is scalar @$jobs, 1, 'one refund is queued' or return;
    is_deeply $jobs->[0]{args}, [ $intent, $sacp->{account}, 4500, $payment->id, $sacp->{slug}, 'wrong_amount' ],
        'of the whole charge, on the studio account, for the payment';

    my $staff = $sacp->{db}->query( q{SELECT message FROM notifications WHERE user_id = ? AND metadata->>'payment_id' = ?},
        $sacp->{admin}, $payment->id )->arrays->flatten->to_array;
    is scalar @$staff, 1, 'the studio admin is alerted';
    like $staff->[0], qr/\$45\.00.*\$90\.00/s, 'with the amount charged and the amount quoted';
    is $db->query( q{SELECT count(*) FROM notifications WHERE user_id = ? AND metadata->>'payment_id' = ?},
        $platform_admin->id, $payment->id )->array->[0], 1, 'and so is the platform';
    is scalar told( $sacp, $sacp->{booker}->id, $run )->@*, 1, 'the booker is told the payment is refunded';
};

done_testing;
