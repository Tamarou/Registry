# ABOUTME: Tests the payment_intent.succeeded webhook finalizes a one-time payment.
# ABOUTME: Covers the off-site (3DS/redirect) safety net plus dedup (#158) and idempotency (#205).
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::StripeWebhook;
use Registry::DAO::Tenant;
use Digest::SHA qw(hmac_sha256_hex);
use Mojo::JSON qw(encode_json);
use Registry::DAO::Family;
use Registry::DAO::Payment;

local $ENV{STRIPE_SECRET_KEY}     = 'sk_test_fake_for_webhook_tests';
local $ENV{STRIPE_WEBHOOK_SECRET} = 'whsec_test_fake_for_webhook_tests';
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_test_fake_for_connect_webhook_tests';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

# Every log line the app writes, kept here instead of on stderr.
my @logs;
$t->app->log->unsubscribe('message');
$t->app->log->level('info');
$t->app->log->on(message => sub ($log, $level, @lines) { push @logs, [ $level, "@lines" ] });

# --- seed a registration's worth of data ---
my $loc = $dao->create(Location => { name => 'PI Studio', slug => 'pi-studio', address_info => {}, metadata => {} });
my $prog = $dao->create(Project => { status => 'published', name => 'PI Camp', program_type_slug => 'summer-camp', metadata => {} });
my $teacher = $dao->create(User => { username => 'pi_teacher', name => 'T', user_type => 'staff', email => 'pit@test.local' });
my $session = $dao->create(Session => {
    name => 'PI Week', start_date => '2026-01-01', end_date => '2026-12-31',
    status => 'published', capacity => 10, metadata => {},
});
my $event = $dao->create(Event => {
    time => '2026-06-15 09:00:00', duration => 60, location_id => $loc->id,
    project_id => $prog->id, teacher_id => $teacher->id, capacity => 10, metadata => {},
});
$session->add_events($db, $event->id);

my $parent = $dao->create(User => { username => 'pi_parent', name => 'PI Parent', user_type => 'parent', email => 'pi@test.local' });
my $child = Registry::DAO::Family->add_child($db, $parent->id, {
    child_name => 'PI Kid', birth_date => '2018-01-01', grade => '3',
    medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
});

# Payment as create_payment would leave it: enrollment_items + tenant snapshot.
my $payment = Registry::DAO::Payment->create($db, {
    user_id  => $parent->id,
    amount_cents => 10000,
    status   => 'pending',
    metadata => {
        enrollment_items => [ { session_id => $session->id, child_id => $child->id } ],
        tenant_slug      => undef,
    },
});
# The intent Registry created for it, stored as create_payment_intent stores it.
$db->update('payments', { stripe_payment_intent_id => 'pi_' . $payment->id }, { id => $payment->id });

sub pi_event ($event_id) {
    return {
        id   => $event_id,
        type => 'payment_intent.succeeded',
        data => { object => {
            id       => 'pi_' . $payment->id,
            metadata => { payment_id => $payment->id },
        } },
    };
}

sub post_webhook ($event) {
    my $payload   = encode_json($event);
    my $timestamp = time();
    my $sig       = hmac_sha256_hex("$timestamp.$payload", $ENV{STRIPE_WEBHOOK_SECRET});
    my $tx = $t->ua->post('/webhooks/stripe' => {
        'stripe-signature' => "t=$timestamp,v1=$sig",
        'Content-Type'     => 'application/json',
    } => $payload);
    return $t->tx($tx);
}

sub enrollment_count {
    scalar @{ $db->select('enrollments', '*', { payment_id => $payment->id })->hashes };
}
sub confirmation_count {
    scalar @{ $db->select('notifications', '*',
        { user_id => $parent->id, type => 'enrollment_confirmation' })->hashes };
}

subtest 'payment_intent.succeeded finalizes the enrollment' => sub {
    post_webhook(pi_event('evt_pi_1'))->status_is(200);
    is enrollment_count(), 1, 'enrollment created from the webhook';
    is confirmation_count(), 1, 'confirmation queued';

    my $refreshed = Registry::DAO::Payment->find($db, { id => $payment->id });
    is $refreshed->status, 'completed', 'payment marked completed';
};

subtest 'duplicate delivery of the same event is deduped (#158)' => sub {
    post_webhook(pi_event('evt_pi_1'))->status_is(200);
    is enrollment_count(), 1, 'no second enrollment from duplicate delivery';
    is confirmation_count(), 1, 'no second confirmation';
};

subtest 'distinct event for the same payment stays idempotent (#205)' => sub {
    # Simulates the webhook firing after the parent-return path already ran:
    # a different event id (so the dedup ledger lets it through) but the same
    # payment -- finalize_enrollment must not duplicate.
    post_webhook(pi_event('evt_pi_2'))->status_is(200);
    is enrollment_count(), 1, 'still one enrollment';
    is confirmation_count(), 1, 'still one confirmation';
};

subtest 'amount mismatch fails loudly and does not finalize (Leg W1)' => sub {
    # A distinct child so this payment's enrollment is genuinely new (the
    # earlier subtests already enrolled $child in $session; a duplicate
    # session/child enrollment would dedupe and never attribute to payment2).
    my $child2 = Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => 'PI Kid Two', birth_date => '2019-02-02', grade => '2',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
    });

    # A fresh payment for this scenario: the intent's captured amount must
    # match the row before the enrollment snapshot is granted.
    my $payment2 = Registry::DAO::Payment->create($db, {
        user_id  => $parent->id,
        amount_cents => 10000,
        status   => 'pending',
        metadata => {
            enrollment_items => [ { session_id => $session->id, child_id => $child2->id } ],
            tenant_slug      => undef,
        },
    });
    $db->update('payments', { stripe_payment_intent_id => 'pi_' . $payment2->id },
        { id => $payment2->id });

    my sub pi2_event ($event_id, $amount) {
        return {
            id   => $event_id,
            type => 'payment_intent.succeeded',
            data => { object => {
                id       => 'pi_' . $payment2->id,
                amount   => $amount,
                metadata => { payment_id => $payment2->id },
            } },
        };
    }

    my sub p2_enrollments {
        scalar @{ $db->select('enrollments', '*', { payment_id => $payment2->id })->hashes };
    }

    # Mismatched amount: row is $100 (10000 cents), event claims 12345.
    post_webhook(pi2_event('evt_pi_amt_bad', 12345))->status_is(500);
    is p2_enrollments(), 0, 'no enrollment granted for a mismatched amount';
    my $after_bad = Registry::DAO::Payment->find($db, { id => $payment2->id });
    isnt $after_bad->status, 'completed', 'payment not completed on mismatch';

    # The failed event's claim was released, and a matching delivery (Stripe
    # retry after the row healed, or the true intent's event) finalizes.
    post_webhook(pi2_event('evt_pi_amt_good', 10000))->status_is(200);
    is p2_enrollments(), 1, 'matching amount finalizes exactly as before';
    my $after_good = Registry::DAO::Payment->find($db, { id => $payment2->id });
    is $after_good->status, 'completed', 'payment completed on matching amount';
};

subtest 'a die mid-finalization leaves no partial enrollment and no claim (Leg 0 Task 1)' => sub {
    # Two children in one cart, so finalization has a midpoint to die at. Without
    # a transaction the first enrollment is already committed when the second
    # dies, and nothing takes it back -- that is the defect this task closes.
    my @kids = map {
        Registry::DAO::Family->add_child($db, $parent->id, {
            child_name => "PI Atomic $_", birth_date => '2017-03-0' . $_, grade => '4',
            medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
        })
    } (1, 2);

    my $payment3 = Registry::DAO::Payment->create($db, {
        user_id  => $parent->id,
        amount_cents => 20000,
        status   => 'pending',
        metadata => {
            enrollment_items => [ map { { session_id => $session->id, child_id => $_->id } } @kids ],
            tenant_slug      => undef,
        },
    });
    $db->update('payments', { stripe_payment_intent_id => 'pi_' . $payment3->id },
        { id => $payment3->id });

    my sub pi3_event ($event_id) {
        return {
            id   => $event_id,
            type => 'payment_intent.succeeded',
            data => { object => {
                id       => 'pi_' . $payment3->id,
                amount   => 20000,
                metadata => { payment_id => $payment3->id },
            } },
        };
    }

    my sub p3_enrollments {
        scalar @{ $db->select('enrollments', '*', { payment_id => $payment3->id })->hashes };
    }

    my sub claim_rows ($event_id) {
        scalar @{ $db->query(
            'SELECT 1 FROM registry.webhook_events WHERE stripe_event_id = ?', $event_id
        )->arrays };
    }

    # Die on the second item only: the first has already been written by then.
    {
        my $real  = \&Registry::DAO::Enrollment::create_for_payment;
        my $calls = 0;
        no warnings 'redefine';
        local *Registry::DAO::Enrollment::create_for_payment = sub {
            die "probe: finalization failed partway\n" if ++$calls == 2;
            return $real->(@_);
        };

        post_webhook(pi3_event('evt_pi_atomic'))->status_is(500);
    }

    is p3_enrollments(), 0,
        'the first item is rolled back with the second -- no partial enrollment';
    is claim_rows('evt_pi_atomic'), 0,
        'the claim does not survive the failure';

    my $after = Registry::DAO::Payment->find($db, { id => $payment3->id });
    isnt $after->status, 'completed', 'payment not completed on a partial failure';

    # Stripe's retry must be able to re-claim the same event id and succeed.
    post_webhook(pi3_event('evt_pi_atomic'))->status_is(200);
    is p3_enrollments(), 2, 'the retry finalizes the whole cart';
};

subtest 'webhook settlement stamps completed_at and preserves metadata (Leg 0 Task 2)' => sub {
    # The webhook wrote two columns and never completed_at, so a webhook-settled
    # payment was indistinguishable from one still pending on that column while
    # a callback-settled one carried a timestamp. Same event, two shapes.
    my $child3 = Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => 'PI Stamp', birth_date => '2016-04-04', grade => '5',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
    });

    my $payment4 = Registry::DAO::Payment->create($db, {
        user_id  => $parent->id,
        amount_cents => 10000,
        status   => 'pending',
        metadata => {
            enrollment_items => [ { session_id => $session->id, child_id => $child3->id } ],
            tenant_slug      => undef,
        },
    });
    $db->update('payments', { stripe_payment_intent_id => 'pi_' . $payment4->id },
        { id => $payment4->id });

    my $before = $db->select('payments', ['completed_at'], { id => $payment4->id })->hash;
    is $before->{completed_at}, undef, 'completed_at starts NULL';

    post_webhook({
        id   => 'evt_pi_stamp',
        type => 'payment_intent.succeeded',
        data => { object => {
            id       => 'pi_' . $payment4->id,
            amount   => 10000,
            metadata => { payment_id => $payment4->id },
        } },
    })->status_is(200);

    my $after = $db->select('payments', ['completed_at'], { id => $payment4->id })->hash;
    ok defined $after->{completed_at},
        'a webhook-settled payment carries completed_at, like a callback-settled one';

    # save() rewrites the whole metadata column rather than patching it, so the
    # enrollment snapshot has to survive the wider write.
    my $refreshed = Registry::DAO::Payment->find($db, { id => $payment4->id });
    is ref $refreshed->metadata->{enrollment_items}, 'ARRAY',
        'the enrollment snapshot survives the metadata rewrite';
    is scalar @{ $refreshed->metadata->{enrollment_items} }, 1,
        'and still holds its one item';
};

subtest 'a delivery onto a settled row does not re-complete it (Leg 0 Task 3)' => sub {
    # The webhook's guard was widened from `status eq 'completed'` to
    # _money_has_moved, which also covers refunded, partially_refunded and
    # refund_pending. That widening is the difference between a redelivery being
    # a no-op and it re-completing a refunded row -- which the capacity gate then
    # re-demotes and refunds a second time. Every other fixture in this file
    # builds a 'pending' payment, so the widened arm was never exercised.
    # A distinct child per status: enrollments_session_student_type_live covers
    # every non-cancelled row, so reusing one child would make the second iteration's
    # finalize_enrollment raise inside the settlement transaction and answer
    # 500 -- a real defect, but not the one under test here.
    my %kid;
    for my $settled (qw( refunded partially_refunded refund_pending )) {
        $kid{$settled} = Registry::DAO::Family->add_child($db, $parent->id, {
            child_name => "PI Settled $settled", birth_date => '2015-05-05',
            grade => '6', medical_info => {},
            emergency_contact => { name => 'x', phone => '5' },
        });
    }

    for my $settled (qw( refunded partially_refunded refund_pending )) {
        my $payment = Registry::DAO::Payment->create($db, {
            user_id => $parent->id, amount_cents => 10000, status => 'pending',
            metadata => {
                enrollment_items => [ { session_id => $session->id, child_id => $kid{$settled}->id } ],
                tenant_slug      => undef },
        });
        $db->update('payments', {
            status => $settled, completed_at => \'NOW()',
            stripe_payment_intent_id => 'pi_settled_' . $payment->id,
        }, { id => $payment->id });

        post_webhook({
            id   => "evt_settled_$settled",
            type => 'payment_intent.succeeded',
            data => { object => {
                id       => 'pi_settled_' . $payment->id,
                amount   => 10000,
                metadata => { payment_id => $payment->id },
            } },
        })->status_is(200);

        my $row = $db->select('payments', ['status','completed_at'],
            { id => $payment->id })->hash;
        is $row->{status}, $settled,
            "a $settled payment is not re-completed by a later delivery";
        ok defined $row->{completed_at}, "and keeps its completion stamp ($settled)";

        # The status guard covers mark_completed only. finalize_enrollment ran
        # below it unconditionally, so a settled row's cart was re-adjudicated
        # and any unseated item seated -- a child enrolled against money that
        # has gone back to the payer. Graded separately from the status,
        # because the status assertion above passes either way.
        #
        # refund_pending is excluded on purpose: that money is owed, not
        # returned, the debt belongs to one child whose seat went, and the rest
        # of the cart must still be adjudicated on redelivery. Asserting
        # zero-enrollments there would have pinned the wrong behaviour and
        # broken the debt-accumulation case in payment-capacity-obligation.t.
        my $enrolled = $db->query(
            q{SELECT COUNT(*) FROM enrollments WHERE payment_id = ?},
            $payment->id)->array->[0];
        if ( $settled eq 'refund_pending' ) {
            is $enrolled, 1,
                'a refund_pending row still adjudicates the rest of its cart';
        }
        else {
            is $enrolled, 0,
                "and no enrollment is created against $settled money";
        }
    }
};

# --- Connect: sellers with their own accounts and schemas ---

my $admin = $dao->create(User => { username => 'pi_conn_admin', name => 'A',
    user_type => 'admin', email => 'pi_conn_admin@test.local' });

# A seller with a schema of its own, a seat to sell, and a family to sell it to.
sub a_seller ($tag) {
    my $slug    = "pi_${tag}_$$";
    my $account = "acct_pi_${tag}_$$";
    Registry::DAO::Tenant->provision($db, {
        name => "PI $tag $$", slug => $slug, users => [$admin],
        stripe_connect_account_id => $account,
        stripe_charges_enabled => 1, stripe_details_submitted => 1 });
    my $tdb = Registry::DAO->new(url => $test_db->uri, schema => $slug)->db;

    my $loc = Registry::DAO::Location->create($tdb, { name => "PI $tag Studio",
        slug => "pi-$tag-studio", address_info => {}, metadata => {} });
    my $prog = Registry::DAO::Project->create($tdb, { name => "PI $tag Camp",
        status => 'published', program_type_slug => 'summer-camp', metadata => {} });
    my $teacher = Registry::DAO::User->create($tdb, { username => "pi_${tag}_teacher",
        name => 'T', user_type => 'staff', email => "pi_${tag}_t\@test.local" });
    my $session = Registry::DAO::Session->create($tdb, { name => "PI $tag Week",
        start_date => '2026-01-01', end_date => '2026-12-31',
        status => 'published', capacity => 10, metadata => {} });
    my $event = Registry::DAO::Event->create($tdb, { time => '2026-06-15 09:00:00',
        duration => 60, location_id => $loc->id, project_id => $prog->id,
        teacher_id => $teacher->id, capacity => 10, metadata => {} });
    $session->add_events($tdb, $event->id);
    my $parent = Registry::DAO::User->create($tdb, { username => "pi_${tag}_parent",
        name => 'P', user_type => 'parent', email => "pi_${tag}_p\@test.local" });

    return { slug => $slug, account => $account, tdb => $tdb,
             session => $session, parent => $parent };
}

my $kids = 0;
sub a_sale ($seller, %extra) {
    my $tdb   = $seller->{tdb};
    my $child = Registry::DAO::Family->add_child($tdb, $seller->{parent}->id, {
        child_name => 'PI Conn Kid ' . ++$kids, birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' } });
    my $sale = Registry::DAO::Payment->create($tdb, {
        user_id => $seller->{parent}->id, amount_cents => 10000, status => 'pending',
        %extra,
        metadata => {
            enrollment_items => [ { session_id => $seller->{session}->id, child_id => $child->id } ],
            tenant_slug      => $seller->{slug} } });
    # The intent Registry created for it, as settle_on names it.
    $tdb->update('payments', { stripe_payment_intent_id => 'pi_conn_' . $sale->id },
        { id => $sale->id });
    return $sale;
}

# Everything a settlement could write in a seller's schema, as one comparable value.
sub ledger ($seller) {
    my $tdb = $seller->{tdb};
    return {
        payments    => $tdb->query(q{SELECT id, status, completed_at, platform_fee_cents
                                     FROM payments ORDER BY id})->hashes->to_array,
        enrollments => $tdb->query('SELECT id FROM enrollments ORDER BY id')->hashes->to_array,
    };
}

my $seller_a = a_seller('a');

subtest 'connect event for charge registry did not make is ignored' => sub {
    a_sale($seller_a);    # something there to leave alone
    my $before = ledger($seller_a);

    for my $case ( [ 'no payment id' => {} ],
                   [ 'unknown payment id' =>
                       { payment_id => '00000000-0000-0000-0000-000000000000' } ] ) {
        my ( $name, $metadata ) = @$case;
        @logs = ();
        Test::Registry::StripeWebhook::post_connect($t, {
            type    => 'payment_intent.succeeded',
            account => $seller_a->{account},
            data    => { object => { id => "pi_counter_$name", amount => 10000,
                                     metadata => $metadata } },
        })->status_is(200, "$name: answered 200");
        ok scalar( grep { $_->[1] =~ /pi_counter_\Q$name\E/ } @logs ), "$name: logged";
    }

    is_deeply ledger($seller_a), $before, 'and no row in the seller schema was created or changed';
};

subtest 'platform endpoint ignores metadata tenant slug' => sub {
    my $sale   = a_sale($seller_a);
    my $before = ledger($seller_a);

    post_webhook({
        id   => "evt_platform_slug_$$",
        type => 'payment_intent.succeeded',
        data => { object => {
            id       => 'pi_platform_slug_' . $sale->id,
            amount   => 10000,
            metadata => { payment_id => $sale->id, tenant_slug => $seller_a->{slug} },
        } },
    })->status_is(200);

    is_deeply ledger($seller_a), $before,
        "the tenant's schema is untouched -- metadata does not choose where to settle";
};

my $seller_b = a_seller('b');

sub sale_status ($seller, $sale) {
    Registry::DAO::Payment->find($seller->{tdb}, { id => $sale->id })->status;
}

sub settle_on ($seller, $sale, %object) {
    return Test::Registry::StripeWebhook::post_connect($t, {
        type    => 'payment_intent.succeeded',
        account => $seller->{account},
        data    => { object => {
            id       => 'pi_conn_' . $sale->id,
            amount   => 10000,
            metadata => { payment_id => $sale->id },
            %object,
        } },
    });
}

subtest 'metadata tenant mismatch settles only in account tenant' => sub {
    my $sale     = a_sale($seller_a);
    my $b_before = ledger($seller_b);

    @logs = ();
    settle_on($seller_a, $sale,
        metadata => { payment_id => $sale->id, tenant_slug => $seller_b->{slug} })
        ->status_is(200);

    is sale_status($seller_a, $sale), 'completed', 'the account names the tenant it settles in';
    is_deeply ledger($seller_b), $b_before, 'the tenant metadata names is untouched';
    ok scalar( grep { $_->[0] eq 'warn'
                      && $_->[1] =~ /\Q$seller_b->{slug}\E/ && $_->[1] =~ /\Q$seller_a->{slug}\E/ } @logs ),
        'and the mismatch is logged';
};

subtest 'payment id from another tenant is not completed' => sub {
    my $sale     = a_sale($seller_b);
    my $b_before = ledger($seller_b);

    settle_on($seller_a, $sale)->status_is(200);

    is sale_status($seller_b, $sale), 'pending', "B's payment is not completed by A's event";
    is_deeply ledger($seller_b), $b_before, "and nothing in B's schema moved";
};

subtest 'explicit zero percent sale records fee zero not null' => sub {
    my $sale = a_sale($seller_a);

    # Stripe omits a zero application fee, so a 0% sale's intent carries none.
    settle_on($seller_a, $sale, application_fee_amount => undef)->status_is(200);

    my $row = $seller_a->{tdb}->select('payments', ['status', 'platform_fee_cents'],
        { id => $sale->id })->hash;
    is $row->{status}, 'completed', 'the sale finalizes';
    is $row->{platform_fee_cents}, 0, 'and records a fee of 0, not NULL';
};

subtest 'settlement failure leaves event unclaimed and nothing behind' => sub {
    # Instalment one, so success would enqueue a schedule job; and a cart naming
    # a child who does not exist, so the enrollment insert fails after the
    # payment has been completed and its fee written in the same transaction.
    my $sale = a_sale($seller_a, instalment_seq => 1, instalment_count => 3);
    $seller_a->{tdb}->query(
        q{UPDATE payments
             SET metadata = jsonb_set(metadata, '{enrollment_items,0,child_id}', to_jsonb(?::text))
           WHERE id = ?}, '00000000-0000-0000-0000-000000000000', $sale->id);
    my $jobs_before = $t->app->minion->jobs({ tasks => ['instalment_schedule'] })->total;

    my $event_id = "evt_conn_fail_$$";
    Test::Registry::StripeWebhook::post_connect($t, {
        id      => $event_id,
        type    => 'payment_intent.succeeded',
        account => $seller_a->{account},
        data    => { object => {
            id => 'pi_conn_' . $sale->id, amount => 10000, application_fee_amount => 300,
            metadata => { payment_id => $sale->id },
        } },
    })->status_is(500);

    my $row = $seller_a->{tdb}->select('payments', ['status', 'platform_fee_cents'],
        { id => $sale->id })->hash;
    is $row->{status}, 'pending', 'the payment is not completed';
    is $row->{platform_fee_cents}, undef, 'no fee is left recorded';
    is $seller_a->{tdb}->select('enrollments', ['id'], { payment_id => $sale->id })->rows, 0,
        'no enrollment is left behind';
    is $t->app->minion->jobs({ tasks => ['instalment_schedule'] })->total, $jobs_before,
        'no schedule job is enqueued';
    is $db->select('registry.webhook_events', ['id'], { stripe_event_id => $event_id })->rows, 0,
        'and the event stays unclaimed for the retry';
};

done_testing;
