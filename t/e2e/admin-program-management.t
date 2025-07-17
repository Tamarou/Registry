use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like is_deeply )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );

# Test complete admin/Morgan journey for program creation and management

{    # Step 1: Admin Account Setup
    my $morgan = $dao->create( User => {
        username => 'morgan',
        password => 'password123',
        email => 'morgan@afterschoolprograms.org',
        name => 'Morgan Smith',
        user_type => 'admin'
    });
    
    ok $morgan, 'Morgan admin account created';
    is $morgan->user_type, 'admin', 'Morgan has admin role';
    is $morgan->name, 'Morgan Smith', 'Morgan name correct';
}

{    # Step 2: Location Setup
    my $morgan = $dao->find( User => { email => 'morgan@afterschoolprograms.org' });
    ok $morgan, 'Morgan found by email';
    
    # Create multiple locations
    my $elementary = $dao->create( Location => {
        name => 'Riverside Elementary',
        slug => 'riverside-elementary',
        address_info => {
            address => '456 River Road',
            capacity => 100
        },
        metadata => {
            facilities => { gymnasium => 1, computer_lab => 1, art_room => 1 }
        }
    });
    
    my $middle_school = $dao->create( Location => {
        name => 'Valley Middle School',
        slug => 'valley-middle',
        address_info => {
            address => '789 Valley Avenue',
            capacity => 150
        },
        metadata => {
            facilities => { gymnasium => 1, computer_lab => 2, science_lab => 1 }
        }
    });
    
    ok $elementary, 'Elementary location created';
    ok $middle_school, 'Middle school location created';
    is $elementary->name, 'Riverside Elementary', 'Elementary name correct';
}


{    # Step 3: Program Type Configuration
    require Registry::DAO::ProgramType;
    
    # Use existing program types that are seeded in the database
    my $afterschool_type = Registry::DAO::ProgramType->find_by_slug($dao->db, 'afterschool');
    my $summer_type = Registry::DAO::ProgramType->find_by_slug($dao->db, 'summer-camp');
    
    ok $afterschool_type, 'After school program type found';
    ok $summer_type, 'Summer camp program type found';
    is $afterschool_type->name, 'After School Program', 'After school program type name correct';
    is $summer_type->name, 'Summer Camp', 'Summer camp program type name correct';
}

{    # Step 4: Program Creation
    my $morgan = $dao->find( User => { email => 'morgan@afterschoolprograms.org' });
    
    # Create STEM program
    my $stem_program = $dao->create( Project => {
        name => 'STEM Explorers',
        notes => 'Hands-on science, technology, engineering, and math activities',
        program_type_slug => 'afterschool',
        metadata => {
            age_range => '6-12',
            learning_objectives => [
                'Introduction to programming concepts',
                'Basic engineering principles',
                'Scientific method exploration'
            ],
            requirements => {
                grade_min => 1,
                grade_max => 6,
                special_needs_accommodation => 1
            }
        }
    });
    
    # Create Arts program
    my $arts_program = $dao->create( Project => {
        name => 'Creative Arts Workshop',
        notes => 'Explore various art mediums and creative expression',
        program_type_slug => 'afterschool',
        metadata => {
            age_range => '5-14',
            learning_objectives => [
                'Develop artistic skills',
                'Explore different art mediums',
                'Build creative confidence'
            ],
            requirements => {
                grade_min => 'K',
                grade_max => 8,
                materials_fee => 25.00
            }
        }
    });
    
    ok $stem_program, 'STEM program created';
    ok $arts_program, 'Arts program created';
    is $stem_program->name, 'STEM Explorers', 'STEM program name correct';
}

{    # Step 5: Session Creation and Scheduling
    my $elementary = $dao->find( Location => { slug => 'riverside-elementary' });
    my $stem_program = $dao->find( Project => { name => 'STEM Explorers' });
    my $arts_program = $dao->find( Project => { name => 'Creative Arts Workshop' });
    
    # Create Fall sessions
    my $stem_fall = $dao->create( Session => {
        name => 'STEM Explorers - Fall 2024',
        project_id => $stem_program->id,
        location_id => $elementary->id,
        start_date => time() + 86400 * 7, # Next week
        end_date => time() + 86400 * (7 + 12*7), # 12 weeks later
        capacity => 20,
        pricing => { standard => 180.00, early_bird => 150.00 }
    });
    
    my $arts_fall = $dao->create( Session => {
        name => 'Creative Arts - Fall 2024',
        project_id => $arts_program->id,
        location_id => $elementary->id,
        start_date => time() + 86400 * 7,
        end_date => time() + 86400 * (7 + 12*7),
        capacity => 15,
        pricing => { standard => 160.00, early_bird => 135.00 }
    });
    
    ok $stem_fall, 'STEM fall session created';
    ok $arts_fall, 'Arts fall session created';
    
    # Create events for each session (12 weeks)
    my $stem_events = 0;
    my $arts_events = 0;
    
    for my $week (0..11) {
        # STEM events - Monday and Wednesday
        for my $day (1, 3) { # Monday = 1, Wednesday = 3
            my $event_time = time() + 86400 * (7 + $week * 7 + $day) + 3600 * 15; # 3 PM
            
            $dao->create( Event => {
                name => "STEM Week " . ($week + 1) . " Day " . (($day == 1) ? "1" : "2"),
                session_id => $stem_fall->id,
                location_id => $elementary->id,
                start_time => $event_time,
                end_time => $event_time + 3600 * 2, # 2 hours
                capacity => 20
            });
            $stem_events++;
        }
        
        # Arts events - Tuesday and Thursday
        for my $day (2, 4) { # Tuesday = 2, Thursday = 4
            my $event_time = time() + 86400 * (7 + $week * 7 + $day) + 3600 * 15; # 3 PM
            
            $dao->create( Event => {
                name => "Arts Week " . ($week + 1) . " Day " . (($day == 2) ? "1" : "2"),
                session_id => $arts_fall->id,
                location_id => $elementary->id,
                start_time => $event_time,
                end_time => $event_time + 3600 * 2, # 2 hours
                capacity => 15
            });
            $arts_events++;
        }
    }
    
    is $stem_events, 24, 'All STEM events created (12 weeks × 2 days)';
    is $arts_events, 24, 'All Arts events created (12 weeks × 2 days)';
}

{    # Step 6: Staff Assignment
    my $morgan = $dao->find( User => { email => 'morgan@afterschoolprograms.org' });
    
    # Create instructor accounts
    my $stem_instructor = $dao->create( User => {
        username => 'alex.teacher',
        password => 'password123',
        email => 'alex.teacher@afterschool.org',
        name => 'Alex Thompson',
        user_type => 'staff'
    });
    
    my $arts_instructor = $dao->create( User => {
        username => 'jamie.artist',
        password => 'password123',
        email => 'jamie.artist@afterschool.org',
        name => 'Jamie Rodriguez',
        user_type => 'staff'
    });
    
    ok $stem_instructor, 'STEM instructor created';
    ok $arts_instructor, 'Arts instructor created';
    
    # Assign instructors to sessions
    my $stem_session = $dao->find( Session => { name => 'STEM Explorers - Fall 2024' });
    my $arts_session = $dao->find( Session => { name => 'Creative Arts - Fall 2024' });
    
    require Registry::DAO::SessionTeacher;
    
    my $stem_assignment = Registry::DAO::SessionTeacher->create($dao->db, {
        session_id => $stem_session->id,
        teacher_id => $stem_instructor->id
    });
    
    my $arts_assignment = Registry::DAO::SessionTeacher->create($dao->db, {
        session_id => $arts_session->id,
        teacher_id => $arts_instructor->id
    });
    
    ok $stem_assignment, 'STEM instructor assigned to session';
    ok $arts_assignment, 'Arts instructor assigned to session';
}

{    # Step 7: Enrollment Management
    # Create families for enrollment testing
    my $families = [];
    
    for my $i (1..25) {
        my $parent = $dao->create( User => {
            username => "parent$i",
            password => 'password123',
            email => "parent$i\@families.com",
            name => "Parent $i",
            user_type => 'parent'
        });
        
        my $child = $dao->create( FamilyMember => {
            family_id => $parent->id,
            child_name => "Child $i",
            birth_date => '2015-03-15',
            grade => ($i % 3 == 0) ? '1st' : (($i % 3 == 1) ? '2nd' : '3rd')
        });
        
        push @$families, { parent => $parent, child => $child };
    }
    
    # Enroll children in sessions (some will need waitlist)
    my $stem_session = $dao->find( Session => { name => 'STEM Explorers - Fall 2024' });
    my $arts_session = $dao->find( Session => { name => 'Creative Arts - Fall 2024' });
    
    my $stem_enrollments = 0;
    my $arts_enrollments = 0;
    
    # Fill STEM session to capacity (20)
    for my $i (0..19) {
        my $family = $families->[$i];
        
        $dao->create( Enrollment => {
            session_id => $stem_session->id,
            family_member_id => $family->{child}->id,
            status => 'active'
        });
        $stem_enrollments++;
    }
    
    # Fill Arts session partially (10 out of 15)
    for my $i (0..9) {
        my $family = $families->[$i];
        
        # Skip if already enrolled in STEM (simulate scheduling conflict)
        next if $i < 20;
        
        $dao->create( Enrollment => {
            session_id => $arts_session->id,
            family_member_id => $family->{child}->id,
            status => 'active'
        });
        $arts_enrollments++;
    }
    
    # Add some children to STEM waitlist (session is full)
    require Registry::DAO::Waitlist;
    my $elementary = $dao->find( Location => { slug => 'riverside-elementary' });
    
    for my $i (20..22) {
        my $family = $families->[$i];
        
        Registry::DAO::Waitlist->join_waitlist(
            $dao->db, $stem_session->id, $elementary->id, 
            $family->{parent}->id, $family->{parent}->id
        );
    }
    
    is $stem_enrollments, 20, 'STEM session filled to capacity';
    
    # Verify waitlist positions
    my $waitlist_entries = Registry::DAO::Waitlist->get_session_waitlist(
        $dao->db, $stem_session->id
    );
    
    is scalar(@$waitlist_entries), 3, 'Three children on STEM waitlist';
    is $waitlist_entries->[0]->position, 1, 'First waitlist position correct';
}

{    # Step 8: Attendance Tracking and Notifications
    my $alex = $dao->find( User => { email => 'alex.teacher@afterschool.org' });
    my $stem_session = $dao->find( Session => { name => 'STEM Explorers - Fall 2024' });
    
    # Get first week's events via session_events junction table
    my $first_week_events = $dao->db->query(q{
        SELECT e.*
        FROM events e
        JOIN session_events se ON e.id = se.event_id
        WHERE se.session_id = ?
        ORDER BY e.time ASC
        LIMIT 2
    }, $stem_session->id)->hashes->to_array;
    
    # Get enrolled students
    my $enrolled_students = $dao->db->query(q{
        SELECT fm.id, fm.child_name, e.id as enrollment_id
        FROM enrollments e
        JOIN family_members fm ON e.family_member_id = fm.id
        WHERE e.session_id = ? AND e.status = 'active'
        LIMIT 10
    }, $stem_session->id)->hashes->to_array;
    
    # Take attendance for first event
    require Registry::DAO::Attendance;
    my $attendance_count = 0;
    
    for my $student (@$enrolled_students) {
        my $status = ($attendance_count % 4 == 0) ? 'absent' : 'present'; # 25% absent rate
        
        Registry::DAO::Attendance->mark_attendance(
            $dao->db, $first_week_events->[0]{id}, $student->{id}, $status, $alex->id
        );
        $attendance_count++;
    }
    
    ok $attendance_count >= 10, 'Attendance taken for first event';
    
    # Verify attendance records
    my $present_count = $dao->db->select('attendance_records', 'COUNT(*)', {
        event_id => $first_week_events->[0]{id},
        status => 'present'
    })->array->[0];
    
    my $absent_count = $dao->db->select('attendance_records', 'COUNT(*)', {
        event_id => $first_week_events->[0]{id},
        status => 'absent'
    })->array->[0];
    
    ok $present_count >= 7, 'Multiple students marked present';
    ok $absent_count >= 1, 'Some students marked absent for notification testing';
}

{    # Step 9: Payment Processing and Financial Tracking
    my $stem_session = $dao->find( Session => { name => 'STEM Explorers - Fall 2024' });
    
    # Process payments for enrolled students
    require Registry::DAO::Payment;
    my $total_revenue = 0;
    my $payment_count = 0;
    
    my $enrollments = $dao->db->select('enrollments', '*', {
        session_id => $stem_session->id,
        status => 'active'
    })->hashes->to_array;
    
    for my $enrollment (@$enrollments) {
        my $amount = ($payment_count % 3 == 0) ? 15000 : 18000; # Mix of early bird and standard
        
        Registry::DAO::Payment->create($dao->db, {
            enrollment_id => $enrollment->{id},
            amount => $amount,
            currency => 'USD',
            status => 'completed',
            payment_method => 'stripe',
            stripe_payment_intent_id => "pi_test_$payment_count",
            metadata => { session_id => $enrollment->{session_id} }
        });
        
        $total_revenue += $amount;
        $payment_count++;
    }
    
    is $payment_count, 20, 'Payments processed for all enrolled students';
    ok $total_revenue >= 300000, 'Total revenue recorded (at least $3000)'; # 20 students × $150+ each
}

{    # Step 10: Program Communication
    my $morgan = $dao->find( User => { email => 'morgan@afterschoolprograms.org' });
    my $stem_session = $dao->find( Session => { name => 'STEM Explorers - Fall 2024' });
    
    # Send welcome message to all STEM parents
    require Registry::DAO::Message;
    
    my $recipients = Registry::DAO::Message->get_recipients_for_scope(
        $dao->db, 'session', $stem_session->id
    );
    
    my @recipient_ids = map { $_->{id} } @$recipients;
    
    my $welcome_message = Registry::DAO::Message->send_message($dao->db, {
        sender_id => $morgan->id,
        subject => 'Welcome to STEM Explorers Fall 2024!',
        body => q{
Dear Families,

Welcome to our STEM Explorers program! We're excited to have your children join us for an amazing semester of learning.

Program Details:
- Classes: Mondays and Wednesdays, 3:00-5:00 PM
- Location: Riverside Elementary Computer Lab
- Instructor: Alex Thompson

What to bring:
- Water bottle
- Notebook and pencil
- Enthusiasm for learning!

We'll be sending regular updates about your child's progress and upcoming projects.

Best regards,
Morgan Smith
Program Director
        },
        message_type => 'announcement',
        scope => 'session',
        scope_id => $stem_session->id
    }, \@recipient_ids, send_now => 1);
    
    ok $welcome_message, 'Welcome message sent to all parents';
    ok $welcome_message->is_sent, 'Message marked as sent';
    is scalar(@recipient_ids), 20, 'Message sent to all 20 families';
}

{    # Step 11: Waitlist Management and Progression
    my $stem_session = $dao->find( Session => { name => 'STEM Explorers - Fall 2024' });
    
    # Simulate a cancellation
    my $enrollment_to_cancel = $dao->find( Enrollment => {
        session_id => $stem_session->id,
        status => 'active'
    });
    
    $enrollment_to_cancel->update($dao->db, { status => 'cancelled' });
    
    # Process waitlist
    my $offered_entry = Registry::DAO::Waitlist->process_waitlist(
        $dao->db, $stem_session->id
    );
    
    ok $offered_entry, 'Waitlist entry offered when spot opened';
    is $offered_entry->status, 'offered', 'First waitlist entry offered spot';
    ok $offered_entry->expires_at > time(), 'Offer expiration time set in future';
    
    # Simulate acceptance
    $offered_entry->accept_offer($dao->db);
    
    # Verify new enrollment
    my $new_enrollment = $dao->find( Enrollment => {
        session_id => $stem_session->id,
        family_member_id => $offered_entry->student_id,
        status => 'pending'
    });
    
    ok $new_enrollment, 'New enrollment created from waitlist acceptance';
    
    # Update to active status
    $new_enrollment->update($dao->db, { status => 'active' });
    
    # Verify enrollment count maintained
    my $active_count = $dao->db->select('enrollments', 'COUNT(*)', {
        session_id => $stem_session->id,
        status => 'active'
    })->array->[0];
    
    is $active_count, 20, 'Session maintains capacity after waitlist progression';
}

{    # Step 12: Admin Dashboard Verification
    my $morgan = $dao->find( User => { email => 'morgan@afterschoolprograms.org' });
    
    # Verify admin can access comprehensive dashboard data
    my $dashboard_stats = $dao->db->query(q{
        SELECT 
            (SELECT COUNT(*) FROM enrollments WHERE status IN ('active', 'pending')) as active_enrollments,
            (SELECT COUNT(*) FROM projects WHERE status = 'active') as active_programs,
            (SELECT COUNT(*) FROM waitlist WHERE status IN ('waiting', 'offered')) as waitlist_entries,
            (SELECT SUM(amount) FROM payments WHERE status = 'completed') as total_revenue
    })->hash;
    
    ok $dashboard_stats, 'Admin dashboard data retrieved';
    ok $dashboard_stats->{active_enrollments} >= 20, 'Active enrollments tracked';
    ok $dashboard_stats->{active_programs} >= 2, 'Active programs tracked';
    ok $dashboard_stats->{waitlist_entries} >= 2, 'Waitlist entries tracked';
    ok $dashboard_stats->{total_revenue} >= 300000, 'Revenue tracked correctly';
    
    # Verify program overview data
    my $program_overview = $dao->db->query(q{
        SELECT 
            p.name as program_name,
            COUNT(DISTINCT s.id) as session_count,
            COUNT(DISTINCT e.id) as total_enrollments,
            SUM(ev.capacity) as total_capacity,
            COUNT(DISTINCT w.id) as waitlist_count
        FROM projects p
        LEFT JOIN sessions s ON p.id = s.project_id
        LEFT JOIN enrollments e ON s.id = e.session_id AND e.status = 'active'
        LEFT JOIN events ev ON s.id = ev.session_id
        LEFT JOIN waitlist w ON s.id = w.session_id AND w.status IN ('waiting', 'offered')
        WHERE p.status = 'active'
        GROUP BY p.id, p.name
        ORDER BY p.name
    })->hashes->to_array;
    
    ok @$program_overview >= 2, 'Program overview shows all programs';
    
    my $stem_overview = (grep { $_->{program_name} eq 'STEM Explorers' } @$program_overview)[0];
    ok $stem_overview, 'STEM program in overview';
    is $stem_overview->{total_enrollments}, 20, 'STEM enrollment count correct';
}

{    # Step 13: End-to-End Data Integrity Verification
    # Verify complete data consistency across all systems
    my $integrity_check = $dao->db->query(q{
        SELECT 
            'enrollments_without_students' as check_type,
            COUNT(*) as violations
        FROM enrollments e 
        LEFT JOIN family_members fm ON e.family_member_id = fm.id 
        WHERE fm.id IS NULL
        
        UNION ALL
        
        SELECT 'attendance_without_events', COUNT(*)
        FROM attendance_records ar 
        LEFT JOIN events ev ON ar.event_id = ev.id 
        WHERE ev.id IS NULL
        
        UNION ALL
        
        SELECT 'payments_without_enrollments', COUNT(*)
        FROM payments p 
        LEFT JOIN enrollments e ON p.enrollment_id = e.id 
        WHERE e.id IS NULL
        
        UNION ALL
        
        SELECT 'waitlist_without_sessions', COUNT(*)
        FROM waitlist w 
        LEFT JOIN sessions s ON w.session_id = s.id 
        WHERE s.id IS NULL
        
        UNION ALL
        
        SELECT 'sessions_without_programs', COUNT(*)
        FROM sessions s 
        LEFT JOIN projects p ON s.project_id = p.id 
        WHERE p.id IS NULL
    })->hashes->to_array;
    
    for my $check (@$integrity_check) {
        is $check->{violations}, 0, "Data integrity check passed: $check->{check_type}";
    }
    
    # Verify financial consistency
    my $financial_check = $dao->db->query(q{
        SELECT 
            COUNT(DISTINCT e.id) as paid_enrollments,
            SUM(p.amount) as total_payments,
            AVG(p.amount) as average_payment
        FROM enrollments e
        JOIN payments p ON e.id = p.enrollment_id
        WHERE e.status = 'active' AND p.status = 'completed'
    })->hash;
    
    ok $financial_check->{paid_enrollments} >= 20, 'All active enrollments have payments';
    ok $financial_check->{total_payments} >= 300000, 'Total payments match expected revenue';
    ok $financial_check->{average_payment} >= 15000, 'Average payment in expected range';
}