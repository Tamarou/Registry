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

# A run entered from somewhere other than the storefront has no location_id, so
# the snapshot has none either -- and waitlist.location_id is NOT NULL. Dropping
# the child there would be a promise made on screen and kept nowhere.
subtest 'a waiting child with no location falls back to where the session meets' => sub {
    my $fourth = Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => 'Fourth Kid', birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
    });

    my $no_location = Registry::DAO::Payment->create($db, {
        user_id      => $parent->id,
        amount_cents => 0,
        metadata     => {
            enrollment_items => [],
            waitlist_items   => [
                { session_id => $full->id, child_id => $fourth->id },
            ],
            tenant_slug => undef,
        },
    });

    $no_location->finalize_enrollment($db);

    my $rows = waitlist_rows( $full, $fourth );
    is scalar(@$rows), 1, 'the child is still queued';
    is $rows->[0]{location_id}, $loc->id, 'at the location the session meets at';
};

# The other half of that fallback: a session with no located event at all. The
# lookup returns no rows, ->array is undef, and the unguarded deref raised
# "Can't use an undefined value as an ARRAY reference" inside the captured
# settlement rather than skipping the child.
subtest 'a session with nowhere to meet skips the child instead of raising' => sub {
    my $unlocated = $dao->create(Session => {
        name => 'Queue Unlocated', start_date => '2026-01-01', end_date => '2026-12-31',
        status => 'published', capacity => 10, metadata => {},
    });
    my $fifth = Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => 'Fifth Kid', birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
    });

    my $nowhere = Registry::DAO::Payment->create($db, {
        user_id      => $parent->id,
        amount_cents => 0,
        metadata     => {
            enrollment_items => [],
            waitlist_items   => [ { session_id => $unlocated->id, child_id => $fifth->id } ],
            tenant_slug => undef,
        },
    });

    my $ok = eval { $nowhere->finalize_enrollment($db); 1 };
    ok $ok, 'the settlement survives it' or diag "raised: $@";
    is scalar @{ waitlist_rows( $unlocated, $fifth ) }, 0,
        'and the child is skipped rather than queued nowhere';
};

# waitlist carries UNIQUE (session_id, student_id) and is_student_waitlisted
# only looks at ('waiting','offered'), so a child who declined an offer, let one
# expire, or accepted one that was later dropped was invisible to the guard and
# fatal to the insert -- inside a transaction Stripe has already captured, which
# rolls back the whole settlement and reproduces identically on every retry.
subtest 'a child who left the queue once can rejoin it' => sub {
    for my $status (qw( declined expired accepted )) {
        my $kid = Registry::DAO::Family->add_child($db, $parent->id, {
            child_name => "Rejoin $status", birth_date => '2018-01-01', grade => '3',
            medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
        });

        # The state the queue itself leaves behind: decline_offer and
        # expire_old_offers both park the row at position 0.
        Registry::DAO::Waitlist->create($db, {
            session_id => $full->id, location_id => $loc->id,
            student_id => $kid->id, parent_id => $parent->id,
            status => $status, position => 0,
        });

        my $rejoin = Registry::DAO::Payment->create($db, {
            user_id      => $parent->id,
            amount_cents => 0,
            metadata     => {
                enrollment_items => [],
                waitlist_items   => [
                    { session_id => $full->id, child_id => $kid->id,
                      location_id => $loc->id },
                ],
                tenant_slug => undef,
            },
        });

        my $ok = eval { $rejoin->finalize_enrollment($db); 1 };
        ok $ok, "a '$status' entry does not take the settlement down"
            or diag "raised: $@";

        my $rows = waitlist_rows( $full, $kid );
        is scalar(@$rows), 1, "'$status': still exactly one entry, not a second";
        is $rows->[0]{status}, 'waiting',
            "'$status': and it is back in the queue rather than left out of it";
        ok $rows->[0]{position}, "'$status': with a position, not parked at 0";
    }
};

done_testing;
