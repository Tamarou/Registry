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

subtest 'a collision the dedup index does not cover is not swallowed' => sub {
    # Dropping an enrollment cancels the row in place; nothing deletes it. So a
    # parent re-registering the same child for the same session collides with
    # enrollments_session_student_type_unique, which the payment dedup index does
    # not cover. Stripe has already captured by the time finalize runs, so a
    # skipped insert here means money taken, no enrollment row, no exception,
    # and a confirmation email sent anyway. It has to raise.
    $db->update('enrollments', { status => 'cancelled' }, { payment_id => $payment->id });

    my $repay = Registry::DAO::Payment->create($db, {
        user_id  => $parent->id,
        amount_cents => 10000,
        metadata => {
            enrollment_items => [ { session_id => $session->id, child_id => $child->id } ],
            tenant_slug      => undef,
        },
    });

    my $ok = eval { $repay->finalize_enrollment($db); 1 };
    my $err = $@;

    ok !$ok, 'finalize raises instead of dropping the insert on the floor';
    like $err, qr/enrollments_session_student_type_unique/,
        'the error names the constraint that actually fired';

    my $rows = $db->select('enrollments', '*', { payment_id => $repay->id })->hashes;
    is scalar(@$rows), 0, 'no enrollment row for the new payment (the raise is the only signal)';
};

done_testing;
