# ABOUTME: Tests that Payment->finalize_enrollment is idempotent (#205).
# ABOUTME: The parent-return callback and the webhook can both finalize a payment.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Family;
use Registry::DAO::Payment;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $loc = $dao->create(Location => {
    name => 'Idem Studio', slug => 'idem-studio', address_info => {}, metadata => {},
});
my $prog = $dao->create(Project => {
    status => 'published', name => 'Idem Camp', program_type_slug => 'summer-camp', metadata => {},
});
my $teacher = $dao->create(User => { username => 'idem_teacher', name => 'T', user_type => 'staff', email => 'it@test.local' });
my $session = $dao->create(Session => {
    name => 'Idem Week', start_date => '2026-01-01', end_date => '2026-12-31',
    status => 'published', capacity => 10, metadata => {},
});
my $event = $dao->create(Event => {
    time => '2026-06-15 09:00:00', duration => 60, location_id => $loc->id,
    project_id => $prog->id, teacher_id => $teacher->id, capacity => 10, metadata => {},
});
$session->add_events($db, $event->id);

my $parent = $dao->create(User => {
    username => 'idem_parent', name => 'Idem Parent', user_type => 'parent', email => 'idem@test.local',
});
my $child = Registry::DAO::Family->add_child($db, $parent->id, {
    child_name => 'Idem Kid', birth_date => '2018-01-01', grade => '3',
    medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
});

my $payment = Registry::DAO::Payment->create($db, {
    user_id  => $parent->id,
    amount_cents => 10000,
    metadata => {
        enrollment_items => [ { session_id => $session->id, child_id => $child->id } ],
        tenant_slug      => undef,
    },
});

subtest 'finalize_enrollment creates enrollment + confirmation once' => sub {
    $payment->finalize_enrollment($db);

    my $enr = $db->select('enrollments', '*', { payment_id => $payment->id })->hashes;
    is scalar(@$enr), 1, 'one enrollment created';
    is $enr->[0]{status}, 'active', 'enrollment is active';

    my $notes = $db->select('notifications', '*',
        { user_id => $parent->id, type => 'enrollment_confirmation' })->hashes;
    is scalar(@$notes), 1, 'one confirmation notification queued';
};

subtest 'second finalize (dual-path) does not duplicate' => sub {
    $payment->finalize_enrollment($db);

    my $enr = $db->select('enrollments', '*', { payment_id => $payment->id })->hashes;
    is scalar(@$enr), 1, 'still exactly one enrollment after second finalize';

    my $notes = $db->select('notifications', '*',
        { user_id => $parent->id, type => 'enrollment_confirmation' })->hashes;
    is scalar(@$notes), 1, 'still exactly one confirmation notification';
};

subtest 'a re-registration after a drop is seated, not refused' => sub {
    # This subtest used to assert the opposite: that finalize RAISES here.
    #
    # That was the least-bad option available at the time. Dropping cancels the
    # row in place, and the old total constraint
    # (enrollments_session_student_type_unique) meant a re-registration collided
    # with the dead row -- so the choice was between raising and silently
    # skipping a seat the parent had paid for. Its own comment says why raising
    # is bad: Stripe has already captured by the time finalize runs, so the
    # raise rolls back a captured settlement, releases the webhook dedup claim,
    # and every redelivery reproduces it. Forever.
    #
    # enrollment-reenrol-after-drop removed the dilemma. The rule is now a
    # partial unique index over live rows only, so a cancelled row stops
    # occupying the seat and the third option -- just enrol the child -- exists.
    # A child dropping and re-joining is ordinary in after-school programmes and
    # the schema now says so.
    $db->update('enrollments', { status => 'cancelled' }, { payment_id => $payment->id });

    my $repay = Registry::DAO::Payment->create($db, {
        user_id  => $parent->id,
        amount_cents => 10000,
        metadata => {
            enrollment_items => [ { session_id => $session->id, child_id => $child->id } ],
            tenant_slug      => undef,
        },
    });

    my $ok  = eval { $repay->finalize_enrollment($db); 1 };
    my $err = $@;

    ok $ok, 'finalize does not raise inside a settlement Stripe already captured'
        or diag "raised: $err";

    my $rows = $db->select('enrollments', '*', { payment_id => $repay->id })->hashes;
    is scalar(@$rows), 1, 'the re-registered child gets an enrollment row';
    isnt $rows->[0]{status}, 'cancelled', 'and it is a live one';

    my $live = $db->query(
        q{SELECT COUNT(*) FROM enrollments
           WHERE session_id = ? AND student_id = ? AND status <> 'cancelled'},
        $session->id, $child->id)->array->[0];
    is $live, 1, 'exactly one live seat -- the cancelled row does not become a second';
};

done_testing;
