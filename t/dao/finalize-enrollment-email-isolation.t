# ABOUTME: Tests F-13 -- finalize_enrollment email side-effect must not abort remaining items.
# ABOUTME: If ensure_enrollment_confirmation throws for one item, the rest still enroll.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Family;
use Registry::DAO::Payment;
use Registry::DAO::Notification;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# ---------------------------------------------------------------------------
# Fixtures: two sessions, one parent, one child
# ---------------------------------------------------------------------------

my $loc = $dao->create( Location => {
    name         => 'F13 Studio',
    slug         => 'f13-studio',
    address_info => {},
    metadata     => {},
} );

my $prog = $dao->create( Project => {
    name              => 'F13 Camp',
    status            => 'published',
    program_type_slug => 'summer-camp',
    metadata          => {},
} );

my $teacher = $dao->create( User => {
    username  => 'f13_teacher',
    name      => 'F13 Teacher',
    user_type => 'staff',
    email     => 'f13_t@test.local',
} );

my $session_a = $dao->create( Session => {
    name       => 'F13 Session A',
    start_date => '2026-07-01',
    end_date   => '2026-07-14',
    status     => 'published',
    capacity   => 10,
    metadata   => {},
} );

my $session_b = $dao->create( Session => {
    name       => 'F13 Session B',
    start_date => '2026-07-15',
    end_date   => '2026-07-28',
    status     => 'published',
    capacity   => 10,
    metadata   => {},
} );

for my $session ($session_a, $session_b) {
    my $event = $dao->create( Event => {
        time        => $session->start_date . ' 09:00:00',
        duration    => 60,
        location_id => $loc->id,
        project_id  => $prog->id,
        teacher_id  => $teacher->id,
        capacity    => 10,
        metadata    => {},
    });
    $session->add_events( $db, $event->id );
}

my $parent = $dao->create( User => {
    username  => 'f13_parent',
    name      => 'F13 Parent',
    user_type => 'parent',
    email     => 'f13_p@test.local',
} );

my $child = Registry::DAO::Family->add_child( $db, $parent->id, {
    child_name         => 'F13 Kid',
    birth_date         => '2018-05-01',
    grade              => '2',
    medical_info       => {},
    emergency_contact  => { name => 'EC', phone => '555-0001' },
});

# Payment enrolling the child in both sessions
my $payment = Registry::DAO::Payment->create( $db, {
    user_id  => $parent->id,
    amount   => 200,
    metadata => {
        enrollment_items => [
            { session_id => $session_a->id, child_id => $child->id },
            { session_id => $session_b->id, child_id => $child->id },
        ],
        tenant_slug => undef,
    },
});

# ---------------------------------------------------------------------------
# Capture warnings emitted by the production code during the test so we can
# assert they appear without letting them pollute TAP output.
# ---------------------------------------------------------------------------

my @captured_warnings;
local $SIG{__WARN__} = sub { push @captured_warnings, @_ };

# ---------------------------------------------------------------------------
# Inject a failure: make ensure_enrollment_confirmation die for the FIRST call
# (session_a) and succeed normally for subsequent calls. We use a call counter
# so only the first invocation fails.
# ---------------------------------------------------------------------------

my $email_call_count = 0;
no warnings 'redefine';
local *Registry::DAO::Notification::ensure_enrollment_confirmation = sub {
    $email_call_count++;
    if ($email_call_count == 1) {
        die "Simulated email transport failure for session_a\n";
    }
    # All other calls proceed normally (no-op for test isolation)
};
use warnings 'redefine';

# ---------------------------------------------------------------------------
# Subtest 1: both enrollments are created even though the first email fails.
# Before the fix, the loop aborts after session_a's email throws and
# session_b's enrollment is never created.
# ---------------------------------------------------------------------------

subtest 'all enrollment items created when first email confirmation throws' => sub {
    $payment->finalize_enrollment($db);

    my $enrollments = $db->select(
        'enrollments', '*', { payment_id => $payment->id }
    )->hashes;

    is scalar(@$enrollments), 2,
        'both enrollment items created despite first email failure';

    my %sessions_enrolled = map { $_->{session_id} => 1 } @$enrollments;
    ok $sessions_enrolled{ $session_a->id }, 'session_a enrollment created';
    ok $sessions_enrolled{ $session_b->id }, 'session_b enrollment created';
};

# ---------------------------------------------------------------------------
# Subtest 2: the email failure is logged via warn (not silently swallowed).
# Per CLAUDE.md: expected errors in logs must be captured and tested.
# ---------------------------------------------------------------------------

subtest 'email failure is logged and not silently discarded' => sub {
    ok @captured_warnings > 0,
        'at least one warning was emitted when the email call threw';

    my $found = grep { /Simulated email transport failure for session_a|enrollment.*confirmation/i } @captured_warnings;
    ok $found,
        'warning includes context about the failing email';
};

# ---------------------------------------------------------------------------
# Subtest 3: second call to finalize_enrollment is idempotent (no regressions).
# ---------------------------------------------------------------------------

subtest 'finalize_enrollment remains idempotent after email isolation fix' => sub {
    # Reset warning capture for this subtest
    @captured_warnings = ();

    # On second call, email is no longer overridden to fail (call count > 1 now)
    $payment->finalize_enrollment($db);

    my $enrollments = $db->select(
        'enrollments', '*', { payment_id => $payment->id }
    )->hashes;

    is scalar(@$enrollments), 2,
        'still exactly two enrollments after second finalize call';
};

done_testing;
