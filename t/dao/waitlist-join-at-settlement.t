# ABOUTME: Tests that a paid registration queues the children it chose to wait for.
# ABOUTME: The waitlist join has to survive the webhook, which never sees the run.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Family;
use Registry::DAO::Payment;
use Registry::DAO::Waitlist;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $loc = $dao->create(Location => {
    name => 'Queue Studio', slug => 'queue-studio', address_info => {}, metadata => {},
});
my $prog = $dao->create(Project => {
    status => 'published', name => 'Queue Camp', program_type_slug => 'summer-camp', metadata => {},
});
my $teacher = $dao->create(User => {
    username => 'queue_teacher', name => 'T', user_type => 'staff', email => 'qt@test.local',
});

# Two sessions: one the paying child takes, one that is already full and is
# what the sibling waits for.
my ($open, $full) = map {
    $dao->create(Session => {
        name => $_, start_date => '2026-01-01', end_date => '2026-12-31',
        status => 'published', capacity => 10, metadata => {},
    })
} 'Queue Open', 'Queue Full';

my $hour = 9;
for my $sess ($open, $full) {
    my $event = $dao->create(Event => {
        time => sprintf('2026-06-15 %02d:00:00', $hour++), duration => 60,
        location_id => $loc->id, project_id => $prog->id, teacher_id => $teacher->id,
        capacity => 10, metadata => {},
    });
    $sess->add_events($db, $event->id);
}

my $parent = $dao->create(User => {
    username => 'queue_parent', name => 'Queue Parent', user_type => 'parent',
    email => 'queue@test.local',
});
my ($seated, $waiting) = map {
    Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => $_, birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
    })
} 'Seated Kid', 'Waiting Kid';

my $payment = Registry::DAO::Payment->create($db, {
    user_id      => $parent->id,
    amount_cents => 10000,
    metadata     => {
        enrollment_items => [ { session_id => $open->id, child_id => $seated->id } ],
        waitlist_items   => [
            { session_id => $full->id, child_id => $waiting->id, location_id => $loc->id },
        ],
        tenant_slug => undef,
    },
});

sub waitlist_rows ( $session, $student ) {
    $db->select( 'waitlist', '*',
        { session_id => $session->id, student_id => $student->id } )->hashes;
}

subtest 'a mixed cart seats one child and queues the other' => sub {
    $payment->finalize_enrollment($db);

    my $enr = $db->select('enrollments', '*', { payment_id => $payment->id })->hashes;
    is scalar(@$enr), 1, 'only the paying child gets an enrollment';
    is $enr->[0]{student_id}, $seated->id, 'and it is the child with a seat';

    my $rows = waitlist_rows( $full, $waiting );
    is scalar(@$rows), 1, 'the waiting child is on the waitlist';
    is $rows->[0]{status}, 'waiting', 'as waiting';
    is $rows->[0]{parent_id}, $parent->id, 'attributed to the parent who registered';
    is $rows->[0]{location_id}, $loc->id, 'at the location the run chose';

    my $stray = waitlist_rows( $open, $seated );
    is scalar(@$stray), 0, 'the seated child is not also queued';
};

subtest 'a redelivery does not queue the child twice' => sub {
    # The parent returning to the success page and the payment_intent.succeeded
    # webhook both finalize. The unique index would raise on the second insert,
    # inside a transaction Stripe has already captured against.
    my $ok = eval { $payment->finalize_enrollment($db); 1 };
    ok $ok, 'the second finalize does not raise' or diag "raised: $@";

    my $rows = waitlist_rows( $full, $waiting );
    is scalar(@$rows), 1, 'still exactly one waitlist entry';
};

subtest 'a cart with nothing to seat still joins the queue' => sub {
    # enrollment_items is empty here. finalize_enrollment returns early when it
    # has nothing to seat, so a cart that is all waiting reaches nothing below
    # that guard -- the join has to happen above it.
    my $third = Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => 'Third Kid', birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
    });

    my $all_waiting = Registry::DAO::Payment->create($db, {
        user_id      => $parent->id,
        amount_cents => 0,
        metadata     => {
            enrollment_items => [],
            waitlist_items   => [
                { session_id => $full->id, child_id => $third->id, location_id => $loc->id },
            ],
            tenant_slug => undef,
        },
    });

    $all_waiting->finalize_enrollment($db);

    my $rows = waitlist_rows( $full, $third );
    is scalar(@$rows), 1, 'the waiting child is queued anyway';
};

subtest 'a child who already holds a seat there is not queued' => sub {
    # Nothing in the UI offers this, but a stale page can post it: the session
    # filled, the child was seated by an earlier cart, and this settlement would
    # queue them for a session they are already in.
    my $held = Registry::DAO::Payment->create($db, {
        user_id      => $parent->id,
        amount_cents => 0,
        metadata     => {
            enrollment_items => [],
            waitlist_items   => [
                { session_id => $open->id, child_id => $seated->id, location_id => $loc->id },
            ],
            tenant_slug => undef,
        },
    });

    my $ok = eval { $held->finalize_enrollment($db); 1 };
    ok $ok, 'finalize does not raise' or diag "raised: $@";

    my $rows = waitlist_rows( $open, $seated );
    is scalar(@$rows), 0, 'the enrolled child is left alone';
};

done_testing;
