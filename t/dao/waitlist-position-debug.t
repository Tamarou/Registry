use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like is_deeply diag )];
defer { done_testing };

use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Waitlist;

# Setup test database
my $t  = Test::Registry::DB->new;
my $db = $t->db;

# Create a test tenant
my $tenant = Test::Registry::Fixtures::create_tenant($db, {
    name => 'Debug Organization',
    slug => 'debug_org',
});

# Create the tenant schema
$db->db->query('SELECT clone_schema(dest_schema => ?)', $tenant->slug);

# Create test users
my @parents;
my @students;
for my $i (1..5) {
    push @parents, Test::Registry::Fixtures::create_user($db, {
        username => "parent_debug_$i",
        password => 'password123',
        user_type => 'parent',
    });

    push @students, Test::Registry::Fixtures::create_user($db, {
        username => "student_debug_$i",
        password => 'password123',
        user_type => 'student',
    });
}

# Copy users to tenant schema
for my $i (0..4) {
    $db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $parents[$i]->id);
    $db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $students[$i]->id);
}

# Switch to tenant schema
$db = $db->schema($tenant->slug);

# Create location and session
my $location = Test::Registry::Fixtures::create_location($db, {
    name => 'Debug Location',
    slug => 'debug-location'
});

my $session = Test::Registry::Fixtures::create_session($db, {
    name => 'Debug Session',
    start_date => '2024-06-01',
    end_date => '2024-08-31',
    capacity => 2
});

sub show_waitlist_state {
    my ($label) = @_;
    my $all_entries = $db->db->select('waitlist', '*', {
        session_id => $session->id
    }, { order_by => { -asc => 'position' } })->hashes;

    diag "\n=== $label ===";
    for my $entry (@$all_entries) {
        diag sprintf("Student %d: pos=%d, status=%s",
            $entry->{student_id} =~ /(\d)$/ ? $1 : 0,
            $entry->{position},
            $entry->{status}
        );
    }
}

# Add 5 students to waitlist
diag "Adding 5 students to waitlist";
for my $i (0..4) {
    my $entry = Registry::DAO::Waitlist->join_waitlist(
        $db, $session->id, $location->id, $students[$i]->id, $parents[$i]->id
    );
    is $entry->position, $i + 1, "Student $i has position " . ($i + 1);
}

show_waitlist_state("After adding all students");

# Process and accept first offer
diag "\nProcessing first offer";
my $offer1 = Registry::DAO::Waitlist->process_waitlist($db, $session->id);
ok $offer1, "First offer created";

show_waitlist_state("After first offer");

diag "\nAccepting first offer";
$offer1->accept_offer($db);

show_waitlist_state("After accepting first offer");

# Check positions after first accept
for my $i (1..4) {
    my $pos = Registry::DAO::Waitlist->get_student_position(
        $db, $session->id, $students[$i]->id
    );
    diag "Student $i calculated position: " . ($pos // 'undef');
}

# Process and decline second offer
diag "\nProcessing second offer";
my $offer2 = Registry::DAO::Waitlist->process_waitlist($db, $session->id);
ok $offer2, "Second offer created";

show_waitlist_state("After second offer");

diag "\nDeclining second offer";
my $offer3 = $offer2->decline_offer($db);
ok $offer3, "Third person offered after decline";

show_waitlist_state("After declining second offer");

# Check final positions
my @waiting = @{Registry::DAO::Waitlist->get_session_waitlist($db, $session->id, 'waiting')};
diag "\nFinal waiting list:";
for my $entry (@waiting) {
    diag sprintf("Entry: pos=%d, status=%s", $entry->position, $entry->status);
}

is scalar(@waiting), 2, "Two students still waiting";
is $waiting[0]->position, 1, "First waiting student has position 1";
is $waiting[1]->position, 2, "Second waiting student has position 2";