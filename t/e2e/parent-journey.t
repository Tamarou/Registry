use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like is_deeply )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );

# Test complete parent journey from discovery to enrollment

{    # Step 1: Program Discovery
    # Create a location and program for discovery
    my $location = $dao->create( Location => {
        name => 'Sunny Elementary',
        slug => 'sunny-elementary',
        address => '123 School Street'
    });
    
    my $program = $dao->create( Project => {
        name => 'After School Robotics',
        description => 'Learn programming and robotics',
        status => 'active'
    });
    
    my $session = $dao->create( Session => {
        name => 'Fall 2024 Robotics',
        project_id => $program->id,
        location_id => $location->id,
        start_date => time() + 86400 * 7, # Next week
        end_date => time() + 86400 * 77, # 11 weeks later
        capacity => 15
    });
    
    # Create events for the session
    for my $week (0..9) {
        $dao->create( Event => {
            name => "Week " . ($week + 1) . " Robotics",
            session_id => $session->id,
            location_id => $location->id,
            start_time => time() + 86400 * (7 + $week * 7) + 3600 * 15, # 3 PM each week
            end_time => time() + 86400 * (7 + $week * 7) + 3600 * 17, # 5 PM each week
            capacity => 15
        });
    }
    
    ok $location, 'Location created for program discovery';
    ok $program, 'Program created for discovery';
    ok $session, 'Session created with events';
}

{    # Step 2: Parent Account Creation
    my $parent = $dao->create( User => {
        email => 'sarah.johnson@email.com',
        name => 'Sarah Johnson',
        role => 'parent'
    });
    
    ok $parent, 'Parent account created successfully';
    is $parent->email, 'sarah.johnson@email.com', 'Parent email correct';
    is $parent->role, 'parent', 'Parent role assigned correctly';
}

{    # Step 3: Child Profile Creation
    my $parent = $dao->find( User => { email => 'sarah.johnson@email.com' });
    
    my $child = $dao->create( FamilyMember => {
        family_id => $parent->id,
        child_name => 'Emma Johnson',
        birth_date => '2015-08-15',
        grade => '3rd',
        medical_info => { allergies => ['nuts'], emergency_contact => 'John Johnson' }
    });
    
    ok $child, 'Child profile created successfully';
    is $child->child_name, 'Emma Johnson', 'Child name correct';
    is $child->grade, '3rd', 'Child grade correct';
}

{    # Step 4: Session Enrollment
    my $parent = $dao->find( User => { email => 'sarah.johnson@email.com' });
    my $child = $dao->find( FamilyMember => { child_name => 'Emma Johnson' });
    my $session = $dao->find( Session => { name => 'Fall 2024 Robotics' });
    
    my $enrollment = $dao->create( Enrollment => {
        session_id => $session->id,
        family_member_id => $child->id,
        status => 'active',
        metadata => { enrolled_via => 'website', payment_status => 'pending' }
    });
    
    ok $enrollment, 'Child enrolled in session successfully';
    is $enrollment->status, 'active', 'Enrollment status is active';
}

{    # Step 5: Payment Processing (simulate)
    my $enrollment = $dao->find( Enrollment => { status => 'active' });
    
    require Registry::DAO::Payment;
    my $payment = Registry::DAO::Payment->create($dao->db, {
        enrollment_id => $enrollment->id,
        amount => 25000, # $250.00 in cents
        currency => 'USD',
        status => 'completed',
        payment_method => 'stripe',
        stripe_payment_intent_id => 'pi_test_12345',
        metadata => { session_id => $enrollment->session_id }
    });
    
    ok $payment, 'Payment record created successfully';
    is $payment->status, 'completed', 'Payment completed successfully';
    is $payment->amount, 25000, 'Payment amount correct';
}

{    # Step 6: Attendance Tracking Over Time
    my $child = $dao->find( FamilyMember => { child_name => 'Emma Johnson' });
    my $session = $dao->find( Session => { name => 'Fall 2024 Robotics' });
    
    # Get events for this session
    my $events = $dao->db->select('events', '*', { 
        session_id => $session->id 
    }, { -asc => 'start_time' })->hashes->to_array;
    
    # Mark attendance for first 3 events
    require Registry::DAO::Attendance;
    my $attendance_count = 0;
    for my $i (0..2) {
        my $event = $events->[$i];
        Registry::DAO::Attendance->mark_attendance(
            $dao->db, $event->{id}, $child->id, 'present', $child->family_id
        );
        $attendance_count++;
    }
    
    # Verify attendance records
    my $attendance_records = $dao->db->select('attendance_records', 'COUNT(*)', {
        student_id => $child->id,
        status => 'present'
    })->array->[0];
    
    is $attendance_records, 3, 'Attendance marked for 3 events';
}

{    # Step 7: Parent Dashboard Usage
    my $parent = $dao->find( User => { email => 'sarah.johnson@email.com' });
    
    # Simulate getting dashboard data
    my $enrollments = $dao->db->query(q{
        SELECT 
            e.id as enrollment_id,
            e.status,
            s.name as session_name,
            p.name as program_name,
            fm.child_name
        FROM enrollments e
        JOIN sessions s ON e.session_id = s.id
        JOIN projects p ON s.project_id = p.id
        JOIN family_members fm ON e.family_member_id = fm.id
        WHERE fm.family_id = ? AND e.status = 'active'
    }, $parent->id)->hashes->to_array;
    
    ok @$enrollments >= 1, 'Parent can see active enrollments on dashboard';
    
    my $enrollment = $enrollments->[0];
    is $enrollment->{child_name}, 'Emma Johnson', 'Child name shown correctly';
    is $enrollment->{session_name}, 'Fall 2024 Robotics', 'Session name shown correctly';
}

{    # Step 8: Message Communication
    my $parent = $dao->find( User => { email => 'sarah.johnson@email.com' });
    my $session = $dao->find( Session => { name => 'Fall 2024 Robotics' });
    
    # Create admin user to send message
    my $admin = $dao->create( User => {
        email => 'admin@school.edu',
        name => 'School Administrator',
        role => 'admin'
    });
    
    # Send message to parent
    require Registry::DAO::Message;
    my $message = Registry::DAO::Message->send_message($dao->db, {
        sender_id => $admin->id,
        subject => 'Welcome to Robotics Program!',
        body => 'Welcome Emma to our robotics program. Classes start next week.',
        message_type => 'announcement',
        scope => 'session',
        scope_id => $session->id
    }, [$parent->id], send_now => 1);
    
    ok $message, 'Message sent to parent successfully';
    ok $message->is_sent, 'Message marked as sent';
    
    # Parent receives and reads message
    my $parent_messages = Registry::DAO::Message->get_messages_for_parent(
        $dao->db, $parent->id
    );
    
    ok @$parent_messages >= 1, 'Parent received message';
    
    my $received_message = $parent_messages->[0];
    is $received_message->{subject}, 'Welcome to Robotics Program!', 'Message subject correct';
}

{    # Step 9: Waitlist Scenario (Different Session)
    my $parent = $dao->find( User => { email => 'sarah.johnson@email.com' });
    my $child = $dao->find( FamilyMember => { child_name => 'Emma Johnson' });
    my $location = $dao->find( Location => { slug => 'sunny-elementary' });
    
    # Create a full session
    my $program2 = $dao->create( Project => {
        name => 'Advanced Art Class',
        description => 'Advanced art techniques',
        status => 'active'
    });
    
    my $full_session = $dao->create( Session => {
        name => 'Fall 2024 Advanced Art',
        project_id => $program2->id,
        location_id => $location->id,
        start_date => time() + 86400 * 14, # Two weeks from now
        end_date => time() + 86400 * 84, # 12 weeks later
        capacity => 2 # Small capacity to test waitlist
    });
    
    # Fill the session
    my $other_parent = $dao->create( User => {
        email => 'other.parent@email.com',
        name => 'Other Parent',
        role => 'parent'
    });
    
    for my $i (1..2) {
        my $other_child = $dao->create( FamilyMember => {
            family_id => $other_parent->id,
            child_name => "Child $i",
            birth_date => '2015-05-01',
            grade => '3rd'
        });
        
        $dao->create( Enrollment => {
            session_id => $full_session->id,
            family_member_id => $other_child->id,
            status => 'active'
        });
    }
    
    # Emma tries to enroll but session is full - goes to waitlist
    require Registry::DAO::Waitlist;
    my $waitlist_entry = Registry::DAO::Waitlist->join_waitlist(
        $dao->db, $full_session->id, $location->id, $child->id, $parent->id
    );
    
    ok $waitlist_entry, 'Child added to waitlist when session full';
    is $waitlist_entry->position, 1, 'Child is first on waitlist';
    ok $waitlist_entry->is_waiting, 'Waitlist status is waiting';
}

{    # Step 10: Waitlist Progression
    my $waitlist_entry = $dao->find( Waitlist => { position => 1 });
    my $parent = $dao->find( User => { email => 'sarah.johnson@email.com' });
    
    # Simulate someone dropping out
    my $enrollment_to_cancel = $dao->find( Enrollment => { 
        session_id => $waitlist_entry->session_id,
        status => 'active'
    });
    
    # Cancel enrollment
    $enrollment_to_cancel->update($dao->db, { status => 'cancelled' });
    
    # Process waitlist
    my $offered_entry = Registry::DAO::Waitlist->process_waitlist(
        $dao->db, $waitlist_entry->session_id
    );
    
    ok $offered_entry, 'Waitlist processed when spot opened';
    is $offered_entry->status, 'offered', 'Waitlist entry status changed to offered';
    ok $offered_entry->expires_at, 'Expiration time set for offer';
    
    # Parent accepts offer
    $offered_entry->accept_offer($dao->db);
    
    # Verify enrollment created
    my $new_enrollment = $dao->find( Enrollment => {
        session_id => $offered_entry->session_id,
        family_member_id => $offered_entry->student_id,
        status => 'pending'
    });
    
    ok $new_enrollment, 'Enrollment created when waitlist offer accepted';
}

{    # Step 11: Notification System Integration
    my $parent = $dao->find( User => { email => 'sarah.johnson@email.com' });
    
    # Set notification preferences
    require Registry::DAO::UserPreference;
    Registry::DAO::UserPreference->set_preference(
        $dao->db, $parent->id, 'attendance_missing', 'email', 1
    );
    
    Registry::DAO::UserPreference->set_preference(
        $dao->db, $parent->id, 'waitlist_offer', 'email', 1
    );
    
    # Verify preferences set
    my $attendance_pref = Registry::DAO::UserPreference->wants_notification(
        $dao->db, $parent->id, 'attendance_missing', 'email'
    );
    
    my $waitlist_pref = Registry::DAO::UserPreference->wants_notification(
        $dao->db, $parent->id, 'waitlist_offer', 'email'
    );
    
    ok $attendance_pref, 'Attendance notification preference set';
    ok $waitlist_pref, 'Waitlist notification preference set';
}

{    # Step 12: Complete Journey Verification
    my $parent = $dao->find( User => { email => 'sarah.johnson@email.com' });
    my $child = $dao->find( FamilyMember => { child_name => 'Emma Johnson' });
    
    # Verify complete data integrity
    my $family_data = $dao->db->query(q{
        SELECT 
            u.name as parent_name,
            u.email as parent_email,
            fm.child_name,
            COUNT(DISTINCT e.id) as enrollments,
            COUNT(DISTINCT ar.id) as attendance_records,
            COUNT(DISTINCT mr.id) as messages_received,
            COUNT(DISTINCT p.id) as payments
        FROM users u
        JOIN family_members fm ON u.id = fm.family_id
        LEFT JOIN enrollments e ON fm.id = e.family_member_id
        LEFT JOIN attendance_records ar ON fm.id = ar.student_id
        LEFT JOIN message_recipients mr ON u.id = mr.recipient_id
        LEFT JOIN payments p ON e.id = p.enrollment_id
        WHERE u.id = ?
        GROUP BY u.id, fm.id
    }, $parent->id)->hash;
    
    ok $family_data, 'Complete family data retrieved';
    is $family_data->{parent_name}, 'Sarah Johnson', 'Parent name preserved';
    is $family_data->{child_name}, 'Emma Johnson', 'Child name preserved';
    ok $family_data->{enrollments} >= 2, 'Multiple enrollments recorded';
    ok $family_data->{attendance_records} >= 3, 'Attendance records present';
    ok $family_data->{messages_received} >= 1, 'Messages received';
    ok $family_data->{payments} >= 1, 'Payment records present';
    
    # Verify referential integrity
    my $orphaned_records = $dao->db->query(q{
        SELECT 'enrollments' as table_name, COUNT(*) as count 
        FROM enrollments e 
        LEFT JOIN family_members fm ON e.family_member_id = fm.id 
        WHERE fm.id IS NULL
        
        UNION ALL
        
        SELECT 'attendance_records', COUNT(*) 
        FROM attendance_records ar 
        LEFT JOIN family_members fm ON ar.student_id = fm.id 
        WHERE fm.id IS NULL
        
        UNION ALL
        
        SELECT 'payments', COUNT(*) 
        FROM payments p 
        LEFT JOIN enrollments e ON p.enrollment_id = e.id 
        WHERE e.id IS NULL
    })->hashes->to_array;
    
    for my $check (@$orphaned_records) {
        is $check->{count}, 0, "No orphaned records in $check->{table_name}";
    }
}