use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like is_deeply )];
defer { done_testing };

use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Waitlist;

# Setup test database
my $t  = Test::Registry::DB->new;
my $db = $t->db;

# Create a test tenant (in registry schema)
my $tenant = Test::Registry::Fixtures::create_tenant($db, {
    name => 'Stress Test Organization',
    slug => 'stress_test_org',
});

# Create the tenant schema with all required tables
$db->db->query('SELECT clone_schema(dest_schema => ?)', $tenant->slug);

# Create test users in registry schema
my $admin = Test::Registry::Fixtures::create_user($db, {
    username => 'admin_stress',
    password => 'password123',
    user_type => 'admin',
});

# Create multiple parents and students for stress testing
my @parents;
my @students;
for my $i (1..10) {
    push @parents, Test::Registry::Fixtures::create_user($db, {
        username => "parent_stress_$i",
        password => 'password123',
        user_type => 'parent',
    });

    push @students, Test::Registry::Fixtures::create_user($db, {
        username => "student_stress_$i",
        password => 'password123',
        user_type => 'student',
    });
}

# Copy users to tenant schema
$db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $admin->id);
for my $i (0..9) {
    $db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $parents[$i]->id);
    $db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $students[$i]->id);
}

# Switch to tenant schema for operations
$db = $db->schema($tenant->slug);

# Create a location
my $location = Test::Registry::Fixtures::create_location($db, {
    name => 'Stress Test Location',
    slug => 'stress-test-location'
});

# Create a session with limited capacity
my $session = Test::Registry::Fixtures::create_session($db, {
    name => 'Stress Test Session',
    start_date => '2024-06-01',
    end_date => '2024-08-31',
    capacity => 3  # Small capacity to force waitlist usage
});

{
    # Test 1: Add multiple students to waitlist and verify positions
    my @waitlist_entries;
    for my $i (0..9) {
        my $entry = Registry::DAO::Waitlist->join_waitlist(
            $db, $session->id, $location->id, $students[$i]->id, $parents[$i]->id
        );
        push @waitlist_entries, $entry;
        is $entry->position, $i + 1, "Student $i has correct position " . ($i + 1);
    }
}

{
    # Test 2: Process multiple offers and accepts/declines with position updates
    # Process first 3 offers (simulate capacity being reached)
    for my $round (1..3) {
        my $offered = Registry::DAO::Waitlist->process_waitlist($db, $session->id);
        ok $offered, "Offer $round created";
        is $offered->status, 'offered', "Offer $round has correct status";

        # Accept the offer
        $offered->accept_offer($db);

        # Verify remaining positions are still correct
        for my $pos (1..(10-$round)) {
            my $student_idx = $round + $pos - 1;
            my $position = Registry::DAO::Waitlist->get_student_position(
                $db, $session->id, $students[$student_idx]->id
            );
            is $position, $pos, "After accepting offer $round, student $student_idx is at position $pos";
        }
    }
}

{
    # Test 3: Mixed accepts and declines with concurrent operations
    # Process an offer
    my $offered = Registry::DAO::Waitlist->process_waitlist($db, $session->id);
    ok $offered, "New offer created after capacity reached";

    # Decline this offer
    my $next_offered = $offered->decline_offer($db);
    ok $next_offered, "Next person offered after decline";

    # Check positions remain consistent
    my @waiting = @{Registry::DAO::Waitlist->get_session_waitlist($db, $session->id, 'waiting')};
    my $expected_pos = 1;
    for my $entry (@waiting) {
        is $entry->position, $expected_pos++, "Waiting list positions remain sequential";
    }
}

{
    # Test 4: Expire offers and verify position integrity
    # Create multiple offers
    my $offer1 = Registry::DAO::Waitlist->process_waitlist($db, $session->id);

    # Manually expire it
    $offer1->update($db, { expires_at => \"NOW() - INTERVAL '1 hour'" });

    # Process expiration
    my $expired = Registry::DAO::Waitlist->expire_old_offers($db);
    ok @$expired >= 1, "Found and expired old offers";

    # Process next waitlist entry
    my $offer2 = Registry::DAO::Waitlist->process_waitlist($db, $session->id);
    ok $offer2, "Can process waitlist after expiration";

    # Clean up offer2 for next test
    if ($offer2) {
        $offer2->update($db, { expires_at => \"NOW() - INTERVAL '1 hour'" });
        Registry::DAO::Waitlist->expire_old_offers($db);
    }

    # Verify positions are still correct
    my @waiting = @{Registry::DAO::Waitlist->get_session_waitlist($db, $session->id, 'waiting')};
    my $pos = 1;
    for my $entry (@waiting) {
        my $calculated_pos = Registry::DAO::Waitlist->get_student_position(
            $db, $session->id, $entry->student_id
        );
        is $calculated_pos, $pos++, "Position correctly calculated after expiration";
    }
}

{
    # Test 5: Rapid succession of status changes
    my @offers;

    # Create 3 offers in rapid succession
    for (1..3) {
        my $offer = Registry::DAO::Waitlist->process_waitlist($db, $session->id);
        if ($offer) {
            push @offers, $offer;
            # Immediately expire it
            $offer->update($db, { expires_at => \"NOW() - INTERVAL '1 hour'" });
        }
    }

    # Expire all at once
    my $expired_batch = Registry::DAO::Waitlist->expire_old_offers($db);
    # May expire more than we created if previous tests left expired offers
    ok @$expired_batch >= scalar(@offers), "Batch expiration works (expired at least our " . scalar(@offers) . " offers)";

    # Verify database consistency
    my $check_sql = q{
        SELECT COUNT(*) as count,
               COUNT(DISTINCT position) as unique_positions
        FROM waitlist
        WHERE session_id = ?
        AND status = 'waiting'
    };

    my $result = $db->db->query($check_sql, $session->id)->hash;
    is $result->{count}, $result->{unique_positions},
       "No duplicate positions after rapid status changes";
}

{
    # Test 6: Verify constraint integrity
    # Try to manually create a duplicate position (should fail or be handled)
    my $remaining_waiting = $db->db->select('waitlist', '*', {
        session_id => $session->id,
        status => 'waiting'
    }, { order_by => { -asc => 'position' }, limit => 2 })->hashes;

    if (@$remaining_waiting >= 2) {
        my $first = $remaining_waiting->[0];
        my $second = $remaining_waiting->[1];

        # Try to set both to same position (should be prevented by constraint)
        eval {
            $db->db->update('waitlist',
                { position => $first->{position} },
                { id => $second->{id} }
            );
        };

        if ($@) {
            like $@, qr/unique|constraint|duplicate/i,
                 "Database prevents duplicate positions as expected";
        } else {
            # If no error, positions should have been automatically adjusted
            my $recheck = $db->db->select('waitlist', '*', {
                session_id => $session->id,
                status => 'waiting'
            }, { order_by => { -asc => 'position' } })->hashes;

            my %positions;
            for my $entry (@$recheck) {
                $positions{$entry->{position}}++;
            }

            my $duplicates = grep { $_ > 1 } values %positions;
            is $duplicates, 0, "No duplicate positions even after manual position update";
        }
    }
}

# Final verification
{
    my $final_check_sql = q{
        SELECT
            COUNT(*) as total_entries,
            COUNT(DISTINCT position) as unique_positions,
            COUNT(CASE WHEN status = 'waiting' THEN 1 END) as waiting_count,
            COUNT(CASE WHEN status = 'offered' THEN 1 END) as offered_count,
            COUNT(CASE WHEN status = 'expired' THEN 1 END) as expired_count,
            COUNT(CASE WHEN status = 'declined' THEN 1 END) as declined_count
        FROM waitlist
        WHERE session_id = ?
    };

    my $stats = $db->db->query($final_check_sql, $session->id)->hash;

    ok $stats->{total_entries} > 0, "Have waitlist entries";
    ok $stats->{waiting_count} >= 0, "Have valid waiting count";
    ok $stats->{offered_count} >= 0, "Have valid offered count";

    # For waiting entries, positions should be unique
    my $waiting_position_check = q{
        SELECT COUNT(*) = COUNT(DISTINCT position) as positions_unique
        FROM waitlist
        WHERE session_id = ? AND status = 'waiting'
    };

    my $unique_check = $db->db->query($waiting_position_check, $session->id)->hash;
    ok $unique_check->{positions_unique}, "All waiting entries have unique positions";
}