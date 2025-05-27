#!/usr/bin/env perl
use v5.34.0;
use warnings;
use utf8;
use experimental qw(signatures);

use Test::More;
use Test::Exception;
use Test::Deep;

use lib 't/lib';
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry::DAO::Waitlist;
use Registry::DAO::Event;

# Setup test database
my $t  = Test::Registry::DB->new;
my $db = $t->db;

# Create a test tenant
my $tenant = Test::Registry::Fixtures->create_tenant($db, {
    name => 'Test Organization',
    slug => 'test-org',
});

# Switch to tenant schema
$db->schema($tenant->slug);

# Create test data
my $parent1 = Test::Registry::Fixtures->create_user($db, {
    name => 'Parent One',
    email => 'parent1@test.com',
});

my $parent2 = Test::Registry::Fixtures->create_user($db, {
    name => 'Parent Two',
    email => 'parent2@test.com',
});

my $student1 = Test::Registry::Fixtures->create_user($db, {
    name => 'Student One',
    email => 'student1@test.com',
});

my $student2 = Test::Registry::Fixtures->create_user($db, {
    name => 'Student Two',
    email => 'student2@test.com',
});

my $student3 = Test::Registry::Fixtures->create_user($db, {
    name => 'Student Three',
    email => 'student3@test.com',
});

my $location = Test::Registry::Fixtures->create_location($db, {
    name => 'Test School',
    capacity => 20,
});

my $project = Test::Registry::Fixtures->create_project($db, {
    name => 'Test Program',
});

my $session = Test::Registry::Fixtures->create_session($db, {
    name => 'Summer 2024',
    start_date => '2024-06-01',
    end_date => '2024-08-31',
});

my $event = Test::Registry::Fixtures->create_event($db, {
    location_id => $location->id,
    project_id => $project->id,
    capacity => 2, # Small capacity to test waitlist
});

# Add event to session
$session->add_events($db, $event->id);

subtest 'Join waitlist' => sub {
    my $entry = Registry::DAO::Waitlist->join_waitlist(
        $db,
        $session->id,
        $location->id,
        $student1->id,
        $parent1->id,
        'Interested in morning sessions'
    );
    
    ok($entry, 'Joined waitlist');
    is($entry->session_id, $session->id, 'Correct session');
    is($entry->location_id, $location->id, 'Correct location');
    is($entry->student_id, $student1->id, 'Correct student');
    is($entry->parent_id, $parent1->id, 'Correct parent');
    is($entry->position, 1, 'First position');
    is($entry->status, 'waiting', 'Status is waiting');
    is($entry->notes, 'Interested in morning sessions', 'Notes saved');
};

subtest 'Multiple students join waitlist' => sub {
    my $entry2 = Registry::DAO::Waitlist->join_waitlist(
        $db,
        $session->id,
        $location->id,
        $student2->id,
        $parent1->id
    );
    
    is($entry2->position, 2, 'Second position');
    
    my $entry3 = Registry::DAO::Waitlist->join_waitlist(
        $db,
        $session->id,
        $location->id,
        $student3->id,
        $parent2->id
    );
    
    is($entry3->position, 3, 'Third position');
};

subtest 'Cannot join waitlist twice' => sub {
    dies_ok {
        Registry::DAO::Waitlist->join_waitlist(
            $db,
            $session->id,
            $location->id,
            $student1->id,
            $parent1->id
        );
    } 'Cannot join waitlist twice';
};

subtest 'Get session waitlist' => sub {
    my $waitlist = Registry::DAO::Waitlist->get_session_waitlist($db, $session->id);
    
    is(@$waitlist, 3, 'Three students on waitlist');
    is($waitlist->[0]->position, 1, 'First position correct');
    is($waitlist->[1]->position, 2, 'Second position correct');
    is($waitlist->[2]->position, 3, 'Third position correct');
};

subtest 'Get student position' => sub {
    my $pos = Registry::DAO::Waitlist->get_student_position($db, $session->id, $student2->id);
    is($pos, 2, 'Student 2 is in position 2');
    
    $pos = Registry::DAO::Waitlist->get_student_position($db, $session->id, $student3->id);
    is($pos, 3, 'Student 3 is in position 3');
};

subtest 'Process waitlist' => sub {
    my $offered = Registry::DAO::Waitlist->process_waitlist($db, $session->id, 48);
    
    ok($offered, 'Offer made');
    is($offered->student_id, $student1->id, 'Offered to first student');
    is($offered->status, 'offered', 'Status changed to offered');
    ok($offered->offered_at, 'Offered timestamp set');
    ok($offered->expires_at, 'Expiration timestamp set');
    ok($offered->expires_at > $offered->offered_at, 'Expires after offered');
};

subtest 'Position reordering on status change' => sub {
    # Get current waitlist
    my $waitlist = Registry::DAO::Waitlist->get_session_waitlist($db, $session->id, 'waiting');
    is(@$waitlist, 2, 'Two students still waiting');
    is($waitlist->[0]->student_id, $student2->id, 'Student 2 still in waiting list');
    is($waitlist->[0]->position, 2, 'Student 2 still has position 2');
    
    # Decline the offer (which should trigger reordering)
    my $offered = Registry::DAO::Waitlist->find($db, {
        session_id => $session->id,
        student_id => $student1->id
    });
    my $next = $offered->decline_offer($db);
    
    # Check positions were reordered
    $waitlist = Registry::DAO::Waitlist->get_session_waitlist($db, $session->id, 'waiting');
    is(@$waitlist, 1, 'One student waiting after decline and new offer');
    is($waitlist->[0]->student_id, $student3->id, 'Student 3 is now waiting');
    is($waitlist->[0]->position, 2, 'Student 3 moved to position 2');
    
    # Check student 2 was offered
    ok($next, 'Next student was offered');
    is($next->student_id, $student2->id, 'Student 2 was offered');
    is($next->status, 'offered', 'Student 2 status is offered');
};

subtest 'Accept waitlist offer' => sub {
    # Get the offered entry for student 2
    my $offered = Registry::DAO::Waitlist->find($db, {
        session_id => $session->id,
        student_id => $student2->id
    });
    
    # Accept the offer
    lives_ok {
        $offered->accept_offer($db);
    } 'Accept offer succeeds';
    
    # Check enrollment was created
    ok(Registry::DAO::Waitlist->is_student_enrolled($db, $session->id, $student2->id), 
       'Student is now enrolled');
    
    # Check waitlist status
    my $updated = Registry::DAO::Waitlist->find($db, { id => $offered->id });
    is($updated->status, 'declined', 'Waitlist entry marked as declined');
};

subtest 'Expire old offers' => sub {
    # Create an expired offer
    my $old_offer = Registry::DAO::Waitlist->create($db, {
        session_id => $session->id,
        location_id => $location->id,
        student_id => $student3->id,
        parent_id => $parent2->id,
        status => 'offered',
        offered_at => time() - 86400 * 3, # 3 days ago
        expires_at => time() - 86400,     # 1 day ago
        position => 99
    });
    
    my $expired = Registry::DAO::Waitlist->expire_old_offers($db);
    
    ok(@$expired > 0, 'Found expired offers');
    my ($expired_entry) = grep { $_->id eq $old_offer->id } @$expired;
    ok($expired_entry, 'Our offer was expired');
    is($expired_entry->status, 'expired', 'Status changed to expired');
};

subtest 'Session integration' => sub {
    my $waitlist = $session->waitlist($db);
    ok($waitlist, 'Got waitlist from session');
    isa_ok($waitlist, 'ARRAY', 'Returns array ref');
    
    my $count = $session->waitlist_count($db);
    ok(defined $count, 'Got waitlist count');
    is($count, scalar(grep { $_->is_waiting } @$waitlist), 'Count matches waiting entries');
};

subtest 'Helper methods' => sub {
    my $waiting = Registry::DAO::Waitlist->create($db, {
        session_id => $session->id,
        location_id => $location->id,
        student_id => $student1->id,
        parent_id => $parent1->id,
        position => 100,
        status => 'waiting'
    });
    
    ok($waiting->is_waiting, 'is_waiting returns true');
    ok(!$waiting->is_offered, 'is_offered returns false');
    ok(!$waiting->offer_is_active, 'offer_is_active returns false for waiting');
};

subtest 'Cannot enroll if already on waitlist' => sub {
    my $new_session = Test::Registry::Fixtures->create_session($db, {
        name => 'Fall 2024',
    });
    
    # Join waitlist
    Registry::DAO::Waitlist->join_waitlist(
        $db,
        $new_session->id,
        $location->id,
        $student1->id,
        $parent1->id
    );
    
    # Try to join again
    dies_ok {
        Registry::DAO::Waitlist->join_waitlist(
            $db,
            $new_session->id,
            $location->id,
            $student1->id,
            $parent1->id
        );
    } 'Cannot join waitlist if already waitlisted';
};

done_testing;