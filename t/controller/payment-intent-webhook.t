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
    amount   => 100,
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
        amount   => 100,
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

done_testing;
