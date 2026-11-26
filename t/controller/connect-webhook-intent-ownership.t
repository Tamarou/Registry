# ABOUTME: Only the intent Registry created settles a payment; a seller's own intent naming our payment_id does not.
# ABOUTME: Also covers escaped warnings, a paid superseded intent's refund and alert, and malformed payment_ids.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::PricingProbe qw( state_platform_terms );
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
# The controller asks for no tenant; the refund job asks for its own by slug.
$t->app->helper(dao => sub ($c, $tenant = undef) {
    defined $tenant ? Registry::DAO->new( url => $test_db->uri, schema => $tenant ) : $dao });

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
state_platform_terms( $db, $slug, { rate => 0 } );

my $loc = Registry::DAO::Location->create($tdb, { time_zone => 'America/New_York', name => 'Own Studio',
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

# A sale whose first intent, $first, a decline retry replaced: the row stores
# "${first}_retry" and lists $first as superseded.
sub a_superseded_sale ($first) {
    my $sale = a_sale( stripe_payment_intent_id => $first );
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_payment_intent_async = sub ($s, $p) {
        Mojo::Promise->resolve({ id => "${first}_retry", client_secret => 'cs' });
    };
    $sale->create_payment_intent_async($tdb)->wait;
    return $sale;
}

sub notices_titled ($user_id, $like) {
    $tdb->query( q{SELECT subject, message FROM notifications
                    WHERE user_id = ? AND subject ILIKE ?},
        $user_id, $like )->hashes->to_array;
}

# The superseded refund job for $intent, run to its end by Minion's own worker,
# retrying at once rather than after the backoff.
sub run_refund_job ($intent) {
    my $minion = $t->app->minion;
    my $job = $minion->jobs({ tasks => ['superseded_refund'], notes => [$intent] })->next
        or return undef;
    my $backoff = $minion->backoff;
    $minion->backoff( sub ($retries) { 0 } );
    $minion->perform_jobs_in_foreground({ id => $job->{id} });
    $minion->backoff($backoff);
    return $minion->job( $job->{id} )->info;
}

subtest 'a superseded Registry intent that succeeds is refunded and staff alerted, nothing settles' => sub {
    my $sale = a_superseded_sale('pi_superseded_first');
    my $row = Registry::DAO::Payment->find($tdb, { id => $sale->id });
    is $row->stripe_payment_intent_id, 'pi_superseded_first_retry', 'the retry is the stored intent';
    is_deeply $row->metadata->{superseded_intent_ids}, ['pi_superseded_first'],
        'and the first is recorded as superseded';

    my $before = settlement($sale);
    my $alerts = sub {
        $tdb->query( q{SELECT count(*) FROM notifications
                        WHERE type = 'general' AND message LIKE '%pi_superseded_first%'} )
            ->array->[0];
    };
    my $alerts_before = $alerts->();

    my ( @refunds, $info );
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
        is scalar @refunds, 0, 'the webhook itself calls Stripe for nothing';
        $info = run_refund_job('pi_superseded_first');
    }

    ok $info, 'the refund is queued as a job';
    is $info->{attempts}, 10, 'with ten attempts';
    is $info->{state}, 'finished', 'which finishes';
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

subtest 'the paying parent is told the duplicate charge was refunded' => sub {
    my $sale = a_superseded_sale('pi_parent_told');
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async = sub ($s, $p) {
            Mojo::Promise->resolve({ id => 're_parent_told', status => 'succeeded' });
        };
        my ( $tx ) = post_intent( 'pi_parent_told', $sale, amount => 1999 );
        $tx->status_is(200);
        is run_refund_job('pi_parent_told')->{state}, 'finished', 'the refund is made';
    }

    my @told = grep { $_->{message} =~ /\$19\.99/ }
        @{ notices_titled( $parent->id, '%refund%' ) };
    is scalar @told, 1, 'the parent who paid is notified once';
    like $told[0]{message}, qr/charged twice|duplicate/i, 'that it was a duplicate charge';
    like $told[0]{message}, qr/refunded/i, 'and that it was refunded';
};

subtest 'a superseded refund that fails its last attempt tells staff to refund by hand, with amount and payment' => sub {
    my $sale = a_superseded_sale('pi_refund_fails');

    my ( $tries, $info ) = (0);
    @logs = ();
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async = sub ($s, $p) {
            $tries++;
            Mojo::Promise->reject("Stripe api_error: try later\n");
        };
        my ( $tx ) = post_intent( 'pi_refund_fails', $sale, amount => 4250 );
        $tx->status_is(200, 'acknowledged; the refund is the job\'s to make');
        $info = run_refund_job('pi_refund_fails');
    }

    is $info->{state}, 'failed', 'the job ends failed';
    is $tries, 10, 'after ten tries at Stripe';

    my $by_hand = notices_titled( $admin->id, '%refund failed%' );
    my @this = grep { $_->{message} =~ /pi_refund_fails/ } @$by_hand;
    is scalar @this, 1, 'staff are told once, at the last attempt';
    like $this[0]{subject}, qr/refund failed/i, 'that the refund failed';
    like $this[0]{message}, qr/\$42\.50/, 'with the amount';
    like $this[0]{message}, qr/\Q${\ $sale->id }\E/, 'and the payment';
    ok scalar( grep { $_->[0] eq 'error' && $_->[1] =~ /pi_refund_fails/
                      && $_->[1] =~ /by hand/ } @logs ),
        'and the platform log says so at error';
};

# Minion refusing the job after the settlement COMMIT. The event is already
# claimed, so Stripe's retry would be ignored: a person has to hear of it.
sub post_with_enqueue_dying ($intent_id, $sale) {
    no warnings qw( redefine once );
    local *Minion::enqueue = sub { die "minion is down\n" };
    return post_intent( $intent_id, $sale );
}

subtest 'a superseded refund that cannot be queued after commit is logged at error and admins alerted' => sub {
    my $sale = a_superseded_sale('pi_enqueue_dies');

    @logs = ();
    my ( $tx, $event_id ) = post_with_enqueue_dying( 'pi_enqueue_dies', $sale );
    $tx->status_is(200, 'acknowledged: a retry of a claimed event does nothing');
    ok processed($event_id), 'the event is claimed and marked processed';
    ok !run_refund_job('pi_enqueue_dies'), 'no refund job exists';

    my @told = grep { $_->{message} =~ /pi_enqueue_dies/ }
        @{ notices_titled( $admin->id, '%not queued%' ) };
    is scalar @told, 1, 'the admin is alerted once';
    like $told[0]{message}, qr/by hand/, 'to do it by hand';
    ok scalar( grep { $_->[0] eq 'error' && $_->[1] =~ /superseded_refund/
                      && $_->[1] =~ /pi_enqueue_dies/ && $_->[1] =~ /minion is down/ } @logs ),
        'and the platform log says so at error';
};

subtest 'an instalment schedule that cannot be queued after commit is logged at error and admins alerted' => sub {
    my $sale = a_sale( stripe_payment_intent_id => 'pi_schedule_enqueue_dies',
                       instalment_seq => 1, instalment_count => 3 );

    @logs = ();
    my ( $tx, $event_id ) = post_with_enqueue_dying( 'pi_schedule_enqueue_dies', $sale );
    $tx->status_is(200, 'acknowledged: a retry of a claimed event does nothing');
    is settlement($sale)->{payment}{status}, 'completed', 'instalment one settled';

    my $id = $sale->id;
    my @told = grep { $_->{message} =~ /\Q$id\E/ }
        @{ notices_titled( $admin->id, '%not queued%' ) };
    is scalar @told, 1, 'the admin is alerted once';
    ok scalar( grep { $_->[0] eq 'error' && $_->[1] =~ /instalment_schedule/
                      && $_->[1] =~ /\Q$id\E/ && $_->[1] =~ /minion is down/ } @logs ),
        'and the platform log says so at error';
};

# Stripe answering a refund with an invalid_request_error will answer it the
# same way on every retry: retrying only delays the person who has to act.
subtest 'a refund create answering charge_already_refunded finishes on the first run and notifies the parent' => sub {
    my $sale = a_superseded_sale('pi_already_refunded');

    my ( $tries, $info ) = (0);
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async = sub ($s, $p) {
            $tries++;
            Mojo::Promise->reject( "Stripe invalid_request_error: Charge ch_x has "
                . "already been refunded. (charge_already_refunded)\n" );
        };
        my ( $tx ) = post_intent( 'pi_already_refunded', $sale, amount => 3100 );
        $tx->status_is(200);
        $info = run_refund_job('pi_already_refunded');
    }

    is $info->{state}, 'finished', 'the job finishes';
    is $tries, 1, 'on its first run';
    my @told = grep { $_->{message} =~ /\$31\.00/ }
        @{ notices_titled( $parent->id, '%refund%' ) };
    is scalar @told, 1, 'the parent is told it was refunded';
    is scalar( grep { $_->{message} =~ /pi_already_refunded/ }
        @{ notices_titled( $admin->id, '%refund failed%' ) } ), 0,
        'and staff are not told to refund it again';
};

subtest 'a refund create answering another invalid_request_error finishes at once and tells staff to refund by hand' => sub {
    my $sale = a_superseded_sale('pi_refund_invalid');

    my ( $tries, $info ) = (0);
    @logs = ();
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async = sub ($s, $p) {
            $tries++;
            Mojo::Promise->reject( "Stripe invalid_request_error: No such "
                . "payment_intent: 'pi_refund_invalid'\n (resource_missing)\n" );
        };
        my ( $tx ) = post_intent( 'pi_refund_invalid', $sale, amount => 1200 );
        $tx->status_is(200);
        $info = run_refund_job('pi_refund_invalid');
    }

    is $info->{state}, 'finished', 'the job finishes';
    is $tries, 1, 'on its first run';
    my @told = grep { $_->{message} =~ /pi_refund_invalid/ }
        @{ notices_titled( $admin->id, '%refund failed%' ) };
    is scalar @told, 1, 'staff are told to refund by hand';
    my @errors = grep { $_->[0] eq 'error' && $_->[1] =~ /pi_refund_invalid/ } @logs;
    ok scalar @errors, 'the platform log says so at error';
    unlike join( '', map { $_->[1] } @errors ), qr/'\n/, 'with Stripe\'s text escaped';
};

# A-B-A: a decline retry stores B and lists A, then a second tab's resubmit
# replays A and stores it again. The stored intent is the live one.
subtest 'a row whose stored intent is also listed superseded settles on success, no refund' => sub {
    my $sale = a_sale( stripe_payment_intent_id => 'pi_aba' );
    $tdb->query( q{UPDATE payments SET metadata = jsonb_set(metadata,
                     '{superseded_intent_ids}', '["pi_aba"]') WHERE id = ?}, $sale->id );

    my $alerts = sub {
        $tdb->query( q{SELECT count(*) FROM notifications
                        WHERE type = 'general' AND message LIKE '%pi_aba%'} )->array->[0];
    };
    my $alerts_before = $alerts->();

    my @refunds;
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async = sub ($s, $p) {
            push @refunds, $p;
            Mojo::Promise->resolve({ id => 're_aba', status => 'succeeded' });
        };
        my ( $tx ) = post_intent( 'pi_aba', $sale );
        $tx->status_is(200);
    }

    my $after = settlement($sale);
    is $after->{payment}{status}, 'completed', 'the payment completes';
    is $after->{enrollments}, 1, 'and the enrollment is created';
    is scalar @refunds, 0, 'no refund is sent to Stripe';
    is $alerts->(), $alerts_before, 'and staff are not alerted';
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
