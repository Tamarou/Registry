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
    name => 'Rapid Test Organization',
    slug => 'rapid_test_org',
});

$db->db->query('SELECT clone_schema(dest_schema => ?)', $tenant->slug);

# Create test users
my @parents;
my @students;
for my $i (1..6) {
    push @parents, Test::Registry::Fixtures::create_user($db, {
        username => "parent_rapid_$i",
        password => 'password123',
        user_type => 'parent',
    });

    push @students, Test::Registry::Fixtures::create_user($db, {
        username => "student_rapid_$i",
        password => 'password123',
        user_type => 'student',
    });
}

# Copy users to tenant schema
for my $i (0..5) {
    $db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $parents[$i]->id);
    $db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $students[$i]->id);
}

# Switch to tenant schema
$db = $db->schema($tenant->slug);

# Create location and session
my $location = Test::Registry::Fixtures::create_location($db, {
    name => 'Rapid Location',
    slug => 'rapid-location'
});

my $session = Test::Registry::Fixtures::create_session($db, {
    name => 'Rapid Session',
    start_date => '2024-06-01',
    end_date => '2024-08-31',
    capacity => 2
});

# Add students to waitlist
for my $i (0..5) {
    my $entry = Registry::DAO::Waitlist->join_waitlist(
        $db, $session->id, $location->id, $students[$i]->id, $parents[$i]->id
    );
}

diag "Initial waitlist created with 6 students";

# Accept first two to fill capacity
for (1..2) {
    my $offer = Registry::DAO::Waitlist->process_waitlist($db, $session->id);
    $offer->accept_offer($db);
}

diag "Capacity filled, 4 students remaining on waitlist";

# Create 3 offers in rapid succession
my @offers;
for my $round (1..3) {
    diag "Creating offer $round";
    my $offer = Registry::DAO::Waitlist->process_waitlist($db, $session->id);
    if ($offer) {
        push @offers, $offer;
        # Immediately expire it
        $offer->update($db, { expires_at => \"NOW() - INTERVAL '1 hour'" });
        diag "Offer $round created and pre-expired";
    }
}

diag "Created " . scalar(@offers) . " offers and pre-expired them";

# Check current state
my $state = $db->db->select('waitlist', ['id', 'status', 'position', 'expires_at'], {
    session_id => $session->id,
    status => 'offered'
})->hashes;

diag "Offered entries before expiration:";
for my $entry (@$state) {
    diag sprintf("  ID: %s, status: %s, position: %d",
        substr($entry->{id}, 0, 8),
        $entry->{status},
        $entry->{position}
    );
}

# Try to expire all at once - first call
diag "\nFirst call to expire_old_offers:";
my $expired_batch = Registry::DAO::Waitlist->expire_old_offers($db);
diag "First batch expired " . scalar(@$expired_batch) . " entries";

# Check state after first expiration
$state = $db->db->select('waitlist', ['id', 'status', 'position'], {
    session_id => $session->id
}, { order_by => { -asc => 'position' } })->hashes;

diag "\nWaitlist state after first expiration:";
for my $entry (@$state) {
    diag sprintf("  ID: %s, status: %s, position: %d",
        substr($entry->{id}, 0, 8),
        $entry->{status},
        $entry->{position}
    );
}

# Try second call (should expire nothing)
diag "\nSecond call to expire_old_offers:";
my $expired_batch2 = Registry::DAO::Waitlist->expire_old_offers($db);
diag "Second batch expired " . scalar(@$expired_batch2) . " entries";

is scalar(@$expired_batch), 3, "First expiration expired 3 entries";
is scalar(@$expired_batch2), 0, "Second expiration expired 0 entries (no duplicates)";

# Check for duplicate positions
my $dup_check = $db->db->query(q{
    SELECT position, COUNT(*) as count
    FROM waitlist
    WHERE session_id = ?
    GROUP BY position
    HAVING COUNT(*) > 1
}, $session->id)->hashes;

is scalar(@$dup_check), 0, "No duplicate positions in database";