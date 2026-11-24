# ABOUTME: Only the intent Registry created settles a payment; a seller's own intent naming our payment_id does not.
# ABOUTME: Also covers escaped warnings, a paid superseded intent's refund and alert, and malformed payment_ids.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::StripeWebhook;
use Registry::DAO::Tenant;
use Registry::DAO::Family;
use Registry::DAO::Payment;

local $ENV{STRIPE_SECRET_KEY}             = 'sk_test_fake_for_intent_ownership';
local $ENV{STRIPE_WEBHOOK_SECRET}         = 'whsec_test_fake_for_intent_ownership';
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_test_fake_for_intent_ownership_connect';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

my @logs;
$t->app->log->unsubscribe('message');
$t->app->log->level('info');
$t->app->log->on(message => sub ($log, $level, @lines) { push @logs, [ $level, "@lines" ] });

my $admin = $dao->create(User => { username => 'own_admin', name => 'A',
    user_type => 'admin', email => 'own_admin@test.local' });

my $slug    = "own_$$";
my $account = "acct_own_$$";
Registry::DAO::Tenant->provision($db, {
    name => "Own $$", slug => $slug, users => [$admin],
    stripe_connect_account_id => $account,
    stripe_charges_enabled => 1, stripe_details_submitted => 1 });
my $tdb = Registry::DAO->new(url => $test_db->uri, schema => $slug)->db;

my $loc = Registry::DAO::Location->create($tdb, { name => 'Own Studio',
    slug => 'own-studio', address_info => {}, metadata => {} });
my $prog = Registry::DAO::Project->create($tdb, { name => 'Own Camp',
    status => 'published', program_type_slug => 'summer-camp', metadata => {} });
my $teacher = Registry::DAO::User->create($tdb, { username => 'own_teacher',
    name => 'T', user_type => 'staff', email => 'own_t@test.local' });
my $session = Registry::DAO::Session->create($tdb, { name => 'Own Week',
    start_date => '2026-01-01', end_date => '2026-12-31',
    status => 'published', capacity => 10, metadata => {} });
my $event = Registry::DAO::Event->create($tdb, { time => '2026-06-15 09:00:00',
    duration => 60, location_id => $loc->id, project_id => $prog->id,
    teacher_id => $teacher->id, capacity => 10, metadata => {} });
$session->add_events($tdb, $event->id);
my $parent = Registry::DAO::User->create($tdb, { username => 'own_parent',
    name => 'P', user_type => 'parent', email => 'own_p@test.local' });

my $kids = 0;
sub a_sale (%extra) {
    my $child = Registry::DAO::Family->add_child($tdb, $parent->id, {
        child_name => 'Own Kid ' . ++$kids, birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' } });
    return Registry::DAO::Payment->create($tdb, {
        user_id => $parent->id, amount_cents => 10000, status => 'pending', %extra,
        metadata => {
            enrollment_items => [ { session_id => $session->id, child_id => $child->id } ],
            tenant_slug      => $slug } });
}

sub settlement ($sale) {
    return {
        payment     => $tdb->select('payments', ['status', 'completed_at', 'platform_fee_cents'],
                           { id => $sale->id })->hash,
        enrollments => $tdb->select('enrollments', ['id'], { payment_id => $sale->id })->rows,
    };
}

sub post_intent ($intent_id, $sale, %object) {
    my $event = {
        type    => 'payment_intent.succeeded',
        account => $account,
        data    => { object => {
            id       => $intent_id,
            amount   => 10000,
            metadata => { payment_id => $sale->id },
            %object,
        } },
    };
    my $tx = Test::Registry::StripeWebhook::post_connect($t, $event);
    return ( $tx, $event->{id} );
}

sub processed ($event_id) {
    my $row = $db->select('registry.webhook_events', ['processed_at'],
        { stripe_event_id => $event_id })->hash;
    return $row && $row->{processed_at};
}

subtest 'a seller-made intent naming our payment settles nothing and warns' => sub {
    my $sale   = a_sale( stripe_payment_intent_id => 'pi_registry_made' );
    my $before = settlement($sale);

    @logs = ();
    my ( $tx, $event_id ) = post_intent( 'pi_seller_made', $sale );
    $tx->status_is(200, 'acknowledged, so Stripe stops retrying');

    is_deeply settlement($sale), $before, 'no completion, no enrollment, no fee';
    ok processed($event_id), 'the event is claimed and marked processed';
    ok scalar( grep { $_->[0] eq 'warn' && $_->[1] =~ /pi_seller_made/
                      && $_->[1] =~ /pi_registry_made/ } @logs ),
        'the mismatch is logged at warn with both intent ids';
};

subtest 'a row with no stored intent settles nothing and warns' => sub {
    my $sale   = a_sale();
    my $before = settlement($sale);

    @logs = ();
    my ( $tx, $event_id ) = post_intent( 'pi_seller_unstored', $sale );
    $tx->status_is(200);

    is_deeply settlement($sale), $before, 'no completion, no enrollment, no fee';
    ok processed($event_id), 'the event is acknowledged';
    ok scalar( grep { $_->[0] eq 'warn' && $_->[1] =~ /pi_seller_unstored/ } @logs ),
        'logged at warn';
};

subtest 'a seller-made intent on instalment one queues no schedule' => sub {
    my $sale = a_sale( stripe_payment_intent_id => 'pi_registry_instalment',
                       instalment_seq => 1, instalment_count => 3 );
    my $jobs_before = $t->app->minion->jobs({ tasks => ['instalment_schedule'] })->total;

    my ( $tx ) = post_intent( 'pi_seller_instalment', $sale );
    $tx->status_is(200);

    is $t->app->minion->jobs({ tasks => ['instalment_schedule'] })->total, $jobs_before,
        'no schedule job is enqueued for a payment that did not settle';
};

subtest 'the intent Registry created still settles' => sub {
    my $sale = a_sale( stripe_payment_intent_id => 'pi_registry_genuine' );

    my ( $tx ) = post_intent( 'pi_registry_genuine', $sale, application_fee_amount => 300 );
    $tx->status_is(200);

    my $after = settlement($sale);
    is $after->{payment}{status}, 'completed', 'the payment completes';
    is $after->{payment}{platform_fee_cents}, 300, 'with the fee Stripe reported';
    is $after->{enrollments}, 1, 'and the enrollment is created';
};

subtest 'the metadata mismatch warning escapes the seller slug' => sub {
    my $sale = a_sale( stripe_payment_intent_id => 'pi_registry_escaped' );

    @logs = ();
    my ( $tx ) = post_intent( 'pi_registry_escaped', $sale,
        metadata => { payment_id => $sale->id, tenant_slug => "x\nERROR forged line" } );
    $tx->status_is(200);

    my @warned = grep { $_->[0] eq 'warn' && $_->[1] =~ /names tenant/ } @logs;
    is scalar @warned, 1, 'the mismatch is warned once';
    unlike $warned[0][1], qr/\n/, 'with no raw newline from the seller';
    like $warned[0][1], qr/x\\x\{a\}ERROR forged line/, 'and the value shown escaped';
};

subtest 'platform endpoint warns on a slug-bearing payment_id with no row' => sub {
    my $sale = a_sale( stripe_payment_intent_id => 'pi_platform_norow' );

    @logs = ();
    Test::Registry::StripeWebhook::post_succeeded( $t, $sale->id, $slug, 'pi_platform_norow' )
        ->status_is(200);

    ok scalar( grep { $_->[0] eq 'warn' && $_->[1] =~ /pi_platform_norow/
                      && $_->[1] =~ /not found/ } @logs ),
        'logged at warn, not info';
    is settlement($sale)->{payment}{status}, 'pending', 'and nothing settled';
};

subtest 'a superseded Registry intent that succeeds is refunded and staff alerted, nothing settles' => sub {
    my $sale = a_sale( stripe_payment_intent_id => 'pi_superseded_first' );

    # The decline path's retry: a fresh intent replaces the first on the row.
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_payment_intent_async = sub ($s, $p) {
            Mojo::Promise->resolve({ id => 'pi_superseded_retry', client_secret => 'cs' });
        };
        $sale->create_payment_intent_async($tdb)->wait;
    }
    my $row = Registry::DAO::Payment->find($tdb, { id => $sale->id });
    is $row->stripe_payment_intent_id, 'pi_superseded_retry', 'the retry is the stored intent';
    is_deeply $row->metadata->{superseded_intent_ids}, ['pi_superseded_first'],
        'and the first is recorded as superseded';

    my $before = settlement($sale);
    my $alerts = sub {
        $tdb->query( q{SELECT count(*) FROM notifications
                        WHERE type = 'general' AND message LIKE '%pi_superseded_first%'} )
            ->array->[0];
    };
    my $alerts_before = $alerts->();

    my @refunds;
    @logs = ();
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async = sub ($s, $p) {
            push @refunds, [ $s->stripe_account, $p ];
            Mojo::Promise->resolve({ id => 're_superseded', status => 'succeeded' });
        };
        my ( $tx, $event_id ) = post_intent( 'pi_superseded_first', $sale );
        $tx->status_is(200, 'acknowledged');
        ok processed($event_id), 'the event is claimed and marked processed';
    }

    is scalar @refunds, 1, 'one refund is sent to Stripe';
    is $refunds[0][0], $account, 'on the seller account the charge was made on';
    is $refunds[0][1]{payment_intent}, 'pi_superseded_first', 'for the superseded intent';
    ok !exists $refunds[0][1]{amount}, 'in full';
    like $refunds[0][1]{_idempotency_key}, qr/pi_superseded_first/, 'under a key for that intent';

    is_deeply settlement($sale), $before, 'no completion, no enrollment, no fee';
    is $alerts->(), $alerts_before + 1, 'the tenant admin is alerted';
    ok scalar( grep { $_->[0] eq 'error' && $_->[1] =~ /pi_superseded_first/ } @logs ),
        'and the platform log says so at error';
};

# A seller-written payment_id goes into WHERE id = ?: a non-UUID was a database
# error and a 500, and a hash an SQL::Abstract operator.
for my $case (
    [ 'a non-UUID',  "not-a-uuid\nERROR forged line" ],
    [ 'a hash',      { '!=' => '00000000-0000-0000-0000-000000000000' } ],
    [ 'an array',    [ '00000000-0000-0000-0000-000000000000' ] ],
) {
    my ( $what, $value ) = @$case;

    subtest "connect endpoint: $what metadata.payment_id answers 200, settles nothing, warns escaped" => sub {
        my $sale   = a_sale( stripe_payment_intent_id => 'pi_malformed_connect' );
        my $before = settlement($sale);

        @logs = ();
        my $event = {
            type    => 'payment_intent.succeeded',
            account => $account,
            data    => { object => { id => 'pi_malformed_connect', amount => 10000,
                                     metadata => { payment_id => $value } } },
        };
        my $tx = Test::Registry::StripeWebhook::post_connect($t, $event);
        $tx->status_is(200);

        is_deeply settlement($sale), $before, 'nothing settles';
        ok processed($event->{id}), 'the event is acknowledged';
        my @warned = grep { $_->[0] eq 'warn' && $_->[1] =~ /not a UUID/ } @logs;
        is scalar @warned, 1, 'warned once';
        unlike $warned[0][1] // '', qr/\n/, 'with no raw newline from the seller';
        ok !( grep { $_->[0] eq 'error' } @logs ), 'and nothing at error';
    };

    subtest "platform endpoint: $what metadata.payment_id answers 200, settles nothing, warns escaped" => sub {
        my $sale   = a_sale( stripe_payment_intent_id => 'pi_malformed_platform' );
        my $before = settlement($sale);

        @logs = ();
        Test::Registry::StripeWebhook::post_succeeded( $t, $value, $slug, 'pi_malformed_platform' )
            ->status_is(200);

        is_deeply settlement($sale), $before, 'nothing settles';
        my @warned = grep { $_->[0] eq 'warn' && $_->[1] =~ /not a UUID/ } @logs;
        is scalar @warned, 1, 'warned once';
        unlike $warned[0][1] // '', qr/\n/, 'with no raw newline';
        ok !( grep { $_->[0] eq 'error' } @logs ), 'and nothing at error';
    };
}

done_testing;
