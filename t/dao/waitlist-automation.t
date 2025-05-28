use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like is_deeply )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );

# Create test data
my $admin = $dao->create( User => {
    email => 'admin@test.com',
    name => 'Test Admin',
    role => 'admin'
});

my $parent1 = $dao->create( User => {
    email => 'parent1@test.com',
    name => 'Test Parent 1', 
    role => 'parent'
});

my $parent2 = $dao->create( User => {
    email => 'parent2@test.com',
    name => 'Test Parent 2',
    role => 'parent'
});

my $student1 = $dao->create( User => {
    email => 'student1@test.com',
    name => 'Test Student 1',
    role => 'student'
});

my $student2 = $dao->create( User => {
    email => 'student2@test.com', 
    name => 'Test Student 2',
    role => 'student'
});

# Create a location
my $location = $dao->create( Location => {
    name => 'Test Location',
    slug => 'test-location',
    address => '123 Test St'
});

# Create a session
my $session = $dao->create( Session => {
    name => 'Test Session',
    location_id => $location->id,
    start_date => time() + 86400, # Tomorrow
    end_date => time() + 86400 * 7, # Next week
    capacity => 2
});

{    # Basic waitlist automation test
    # Add two students to waitlist
    my $waitlist1 = Registry::DAO::Waitlist->join_waitlist(
        $dao->db, $session->id, $location->id, $student1->id, $parent1->id
    );
    
    my $waitlist2 = Registry::DAO::Waitlist->join_waitlist(
        $dao->db, $session->id, $location->id, $student2->id, $parent2->id
    );
    
    ok $waitlist1, 'First student joined waitlist';
    ok $waitlist2, 'Second student joined waitlist';
    is $waitlist1->position, 1, 'First student in position 1';
    is $waitlist2->position, 2, 'Second student in position 2';
}

{    # Test waitlist processing
    # Process waitlist (simulate spot opening)
    my $offered_entry = Registry::DAO::Waitlist->process_waitlist($dao->db, $session->id);
    
    ok $offered_entry, 'Waitlist processing returned entry';
    is $offered_entry->status, 'offered', 'Entry status changed to offered';
    ok $offered_entry->offered_at, 'Offered timestamp set';
    ok $offered_entry->expires_at, 'Expiration timestamp set';
}

{    # Test offer acceptance
    # Get the offered entry
    my $offered = Registry::DAO::Waitlist->find($dao->db, { 
        session_id => $session->id, 
        status => 'offered' 
    });
    
    ok $offered, 'Found offered entry';
    
    # Accept the offer
    $offered->accept_offer($dao->db);
    
    # Verify enrollment was created
    my $enrollment = $dao->db->select('enrollments', '*', {
        session_id => $session->id,
        student_id => $offered->student_id
    })->hash;
    
    ok $enrollment, 'Enrollment created after accepting offer';
    is $enrollment->{status}, 'pending', 'Enrollment status is pending';
}

{    # Test offer expiration
    # Add another student to waitlist
    my $student3 = $dao->create( User => {
        email => 'student3@test.com',
        name => 'Test Student 3',
        role => 'student'
    });
    
    my $parent3 = $dao->create( User => {
        email => 'parent3@test.com',
        name => 'Test Parent 3',
        role => 'parent'
    });
    
    my $waitlist3 = Registry::DAO::Waitlist->join_waitlist(
        $dao->db, $session->id, $location->id, $student3->id, $parent3->id
    );
    
    # Process waitlist to create an offer
    my $offered_entry = Registry::DAO::Waitlist->process_waitlist($dao->db, $session->id);
    ok $offered_entry, 'New offer created';
    
    # Manually expire the offer by setting expires_at to past
    $offered_entry->update($dao->db, { expires_at => time() - 3600 }); # 1 hour ago
    
    # Test expiration check
    my $expired_entries = Registry::DAO::Waitlist->expire_old_offers($dao->db);
    
    ok @$expired_entries >= 1, 'Found expired entries';
    
    # Refresh the entry and check status
    $offered_entry = Registry::DAO::Waitlist->find($dao->db, { id => $offered_entry->id });
    is $offered_entry->status, 'expired', 'Entry marked as expired';
}

{    # Test helper methods
    my $waitlist_entry = Registry::DAO::Waitlist->find($dao->db, { 
        session_id => $session->id,
        status => 'waiting'
    });
    
    if ($waitlist_entry) {
        ok $waitlist_entry->is_waiting, 'is_waiting method works';
        ok !$waitlist_entry->is_offered, 'is_offered method works for waiting entry';
        ok !$waitlist_entry->offer_is_active, 'offer_is_active returns false for waiting';
    }
}

{    # Test position tracking
    my $position = Registry::DAO::Waitlist->get_student_position(
        $dao->db, $session->id, $student2->id
    );
    
    # Should be position 1 since first student was promoted/accepted
    is $position, 1, 'Position correctly tracked after promotion';
}