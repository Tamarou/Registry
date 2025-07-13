use 5.40.2;
use Object::Pad;

class Registry::DAO::Event :isa(Registry::DAO::Object) {
    use Carp         qw( carp );
    use experimental qw(try);

    field $id :param :reader;
    field $location_id :param;
    field $project_id :param;
    field $teacher_id :param;
    field $min_age :param :reader;
    field $max_age :param :reader;
    field $capacity :param :reader;
    # TODO: Event class needs:
    # - Remove //= {} default
    # - Add BUILD for JSON decoding
    # - Use { -json => $metadata } in create/update
    # - Add explicit metadata() accessor
    field $metadata :param :reader //= {};
    field $notes :param :reader    //= '';
    field $created_at :param :reader;
    field $updated_at :param :reader;

    sub table { 'events' }

    sub create ( $class, $db, $data ) {
        $class->SUPER::create( $db, $data );
    }

    method location ($db) {
        Registry::DAO::Location->find( $db, { id => $location_id } );
    }

    method teacher ($db) {
        Registry::DAO::User->find( $db, { id => $teacher_id } );
    }

    method project ($db) {
        Registry::DAO::Project->find( $db, { id => $project_id } );
    }

    # Get sessions this event belongs to
    method sessions($db) {

        # TODO optimize this with a join
        $db->select( 'session_events', '*', { event_id => $id } )->hashes->map(
            sub {
                Registry::DAO::Session->find( $db, { id => $_->{session_id} } );
            }
        )->to_array->@*;
    }

    # Helper method to check if event is age-appropriate for a student
    method is_age_appropriate($age) {
        return 1 unless defined $min_age || defined $max_age;
        return 0 if defined $min_age && $age < $min_age;
        return 0 if defined $max_age && $age > $max_age;
        return 1;
    }

    # Helper method to check if event is at capacity
    method is_at_capacity {
        return 0 unless defined $capacity && $capacity > 0;

        # In a real implementation, we'd count enrollments
        # This is a stub for demonstration
        my $current_enrollment = 0;    # Replace with actual count
        return $current_enrollment >= $capacity;
    }

    # Helper method to get available capacity
    method available_capacity {
        return undef unless defined $capacity;

        # In a real implementation, we'd count enrollments
        # This is a stub for demonstration
        my $current_enrollment = 0;    # Replace with actual count
        return $capacity - $current_enrollment;
    }
    
    # Get attendance records for this event
    method attendance_records($db) {
        require Registry::DAO::Attendance;
        Registry::DAO::Attendance->get_event_attendance($db, $id);
    }
    
    # Get attendance summary for this event
    method attendance_summary($db) {
        require Registry::DAO::Attendance;
        Registry::DAO::Attendance->get_event_summary($db, $id);
    }
    
    # Get events for a teacher on a specific date
    sub get_teacher_events_for_date($class, $db, $teacher_id, $date, %opts) {
        my $tenant = $opts{tenant} // 'public';
        
        my $results = $db->query(qq{
            SELECT 
                e.id,
                e.metadata->>'title' as title,
                e.metadata->>'start_time' as start_time,
                e.metadata->>'end_time' as end_time,
                l.name as location_name,
                l.address,
                p.name as program_name,
                COUNT(en.id) as enrolled_count,
                e.capacity
            FROM registry.events e
            JOIN registry.locations l ON e.location_id = l.id
            JOIN registry.projects p ON e.project_id = p.id
            LEFT JOIN registry.sessions s ON s.project_id = p.id
            LEFT JOIN registry.enrollments en ON en.session_id = s.id AND en.status = 'active'
            JOIN registry.session_teachers st ON st.teacher_id = ?
            WHERE DATE(CAST(e.metadata->>'start_time' AS timestamp)) = ?
              AND l.tenant = ?
            GROUP BY e.id, e.metadata, l.name, l.address, p.name, e.capacity
            ORDER BY CAST(e.metadata->>'start_time' AS timestamp)
        }, $teacher_id, $date, $tenant);
        
        return $results->hashes->to_array;
    }
    
    # Get upcoming events for a teacher (next N days)
    sub get_teacher_upcoming_events($class, $db, $teacher_id, $days, %opts) {
        my $tenant = $opts{tenant} // 'public';
        my $end_date = DateTime->today->add(days => $days)->ymd;
        
        my $results = $db->query(qq{
            SELECT 
                e.id,
                e.metadata->>'title' as title,
                e.metadata->>'start_time' as start_time,
                e.metadata->>'end_time' as end_time,
                l.name as location_name,
                l.address,
                p.name as program_name,
                COUNT(en.id) as enrolled_count,
                e.capacity
            FROM registry.events e
            JOIN registry.locations l ON e.location_id = l.id
            JOIN registry.projects p ON e.project_id = p.id
            LEFT JOIN registry.sessions s ON s.project_id = p.id
            LEFT JOIN registry.enrollments en ON en.session_id = s.id AND en.status = 'active'
            JOIN registry.session_teachers st ON st.teacher_id = ?
            WHERE DATE(CAST(e.metadata->>'start_time' AS timestamp)) > CURRENT_DATE
              AND DATE(CAST(e.metadata->>'start_time' AS timestamp)) <= ?
              AND l.tenant = ?
            GROUP BY e.id, e.metadata, l.name, l.address, p.name, e.capacity
            ORDER BY CAST(e.metadata->>'start_time' AS timestamp)
        }, $teacher_id, $end_date, $tenant);
        
        return $results->hashes->to_array;
    }
}

# Note: Pricing class has been replaced by Registry::DAO::PricingPlan
# to support multiple pricing tiers per session