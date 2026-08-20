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
use Digest::SHA qw(hmac_sha256_hex);
use Mojo::JSON qw(encode_json);
use Registry::DAO::Family;
use Registry::DAO::Payment;

local $ENV{STRIPE_SECRET_KEY}     = 'sk_test_fake_for_webhook_tests';
local $ENV{STRIPE_WEBHOOK_SECRET} = 'whsec_test_fake_for_webhook_tests';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

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
    # A distinct child per status: enrollments_session_student_type_unique is
    # status-blind, so reusing one child would make the second iteration's
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
    }
};

done_testing;
