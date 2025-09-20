use 5.40.2;
use Object::Pad;

class Registry::DAO::Event :isa(Registry::DAO::Object) {
    use Carp         qw( carp );
    use DateTime;
    use experimental qw(try);

    field $id :param :reader;
    field $time :param :reader = undef;
    field $duration :param :reader = undef;
    field $location_id :param :reader = undef;
    field $project_id :param :reader = undef;
    field $session_id :param :reader = undef;
    field $teacher_id :param :reader = undef;
    field $metadata :param :reader = {};
    field $notes :param :reader = '';
    field $created_at :param :reader = undef;
    field $updated_at :param :reader = undef;
    field $min_age :param :reader = undef;
    field $max_age :param :reader = undef;
    field $capacity :param :reader = undef;

    sub table { 'events' }

    sub create ( $class, $db, $data ) {
        # Convert start_time/end_time to time/duration if needed
        if (exists $data->{start_time} && exists $data->{end_time}) {
            $data->{time} = $data->{start_time};
            # Calculate duration in minutes
            my $duration_obj = $data->{end_time} - $data->{start_time};
            $data->{duration} = int($duration_obj->in_units('minutes'));
            delete $data->{start_time};
            delete $data->{end_time};
        }
        
        # Store session_id for later linking
        my $session_id = delete $data->{session_id};
        
        # Handle JSON field encoding
        if (exists $data->{metadata} && ref $data->{metadata}) {
            $data->{metadata} = { -json => $data->{metadata} };
        }
        
        my $event = $class->SUPER::create( $db, $data );
        
        # Link to session via session_events junction table
        if ($session_id) {
            $db->insert('session_events', {
                session_id => $session_id,
                event_id => $event->id
            });
        }
        
        return $event;
    }

    method location ($db) {
        Registry::DAO::Location->find( $db, { id => $location_id } );
    }

    method teacher ($db) {
        Registry::DAO::User->find( $db, { id => $teacher_id } );
    }

    method session ($db) {
        Registry::DAO::Session->find( $db, { id => $session_id } );
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

    # Note: Age and capacity constraints are now stored in metadata if needed
    # These constraints can be accessed via $self->metadata->{min_age}, etc.
    
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
    
    # Get the project (curriculum) associated with this event
    method project($db) {
        return unless $project_id;
        
        require Registry::DAO::Project;
        Registry::DAO::Project->find($db, { id => $project_id });
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
                p.name as program_name,
                COUNT(en.id) as enrolled_count,
                e.metadata->>'capacity' as capacity
            FROM registry.events e
            JOIN registry.locations l ON e.location_id = l.id
            JOIN registry.projects p ON e.project_id = p.id
            LEFT JOIN registry.sessions s ON s.project_id = p.id
            LEFT JOIN registry.enrollments en ON en.session_id = s.id AND en.status = 'active'
            JOIN registry.session_teachers st ON st.teacher_id = ?
            WHERE DATE(CAST(e.metadata->>'start_time' AS timestamp)) = ?
            GROUP BY e.id, e.metadata, l.name, p.name
            ORDER BY CAST(e.metadata->>'start_time' AS timestamp)
        }, $teacher_id, $date);
        
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
                p.name as program_name,
                COUNT(en.id) as enrolled_count,
                e.metadata->>'capacity' as capacity
            FROM registry.events e
            JOIN registry.locations l ON e.location_id = l.id
            JOIN registry.projects p ON e.project_id = p.id
            LEFT JOIN registry.sessions s ON s.project_id = p.id
            LEFT JOIN registry.enrollments en ON en.session_id = s.id AND en.status = 'active'
            JOIN registry.session_teachers st ON st.teacher_id = ?
            WHERE DATE(CAST(e.metadata->>'start_time' AS timestamp)) > CURRENT_DATE
              AND DATE(CAST(e.metadata->>'start_time' AS timestamp)) <= ?
            GROUP BY e.id, e.metadata, l.name, p.name
            ORDER BY CAST(e.metadata->>'start_time' AS timestamp)
        }, $teacher_id, $end_date);
        
        return $results->hashes->to_array;
    }
    
    # Attendance monitoring methods for background jobs
    
    # Find events that started in the last 15 minutes but don't have attendance records
    sub find_events_missing_attendance($class, $db) {
        my $sql = q{
            SELECT 
                e.id,
                e.teacher_id,
                e.metadata->>'title' as title,
                e.time as start_time,
                e.time + (e.duration || ' minutes')::interval as end_time,
                l.name as location_name,
                p.name as program_name,
                COUNT(en.id) as enrolled_count
            FROM events e
            JOIN locations l ON e.location_id = l.id
            JOIN projects p ON e.project_id = p.id
            LEFT JOIN session_events se ON e.id = se.event_id
            LEFT JOIN sessions s ON se.session_id = s.id
            LEFT JOIN enrollments en ON en.session_id = s.id AND en.status = 'active'
            WHERE 
                -- Event started in the last 15 minutes
                e.time BETWEEN 
                    now() - interval '15 minutes' AND now()
                -- And has no attendance records
                AND NOT EXISTS (
                    SELECT 1 FROM attendance_records ar 
                    WHERE ar.event_id = e.id
                )
                -- And has enrolled students
                AND EXISTS (
                    SELECT 1 FROM enrollments en2 
                    JOIN sessions s2 ON en2.session_id = s2.id 
                    JOIN session_events se2 ON s2.id = se2.session_id
                    JOIN events e2 ON se2.event_id = e2.id
                    WHERE e2.project_id = e.project_id 
                    AND en2.status = 'active'
                )
            GROUP BY e.id, e.teacher_id, e.metadata, l.name, p.name
            ORDER BY e.time DESC
        };
        
        return $db->query($sql)->hashes->to_array;
    }
    
    # Find events starting in the next 5 minutes
    sub find_events_starting_soon($class, $db) {
        my $sql = q{
            SELECT 
                e.id,
                e.teacher_id,
                e.metadata->>'title' as title,
                e.time as start_time,
                e.time + (e.duration || ' minutes')::interval as end_time,
                l.name as location_name,
                p.name as program_name,
                COUNT(en.id) as enrolled_count
            FROM events e
            JOIN locations l ON e.location_id = l.id
            JOIN projects p ON e.project_id = p.id
            LEFT JOIN session_events se ON e.id = se.event_id
            LEFT JOIN sessions s ON se.session_id = s.id
            LEFT JOIN enrollments en ON en.session_id = s.id AND en.status = 'active'
            WHERE 
                -- Event starts in the next 5 minutes
                e.time BETWEEN 
                    now() AND now() + interval '5 minutes'
                -- And has enrolled students
                AND EXISTS (
                    SELECT 1 FROM enrollments en2 
                    JOIN sessions s2 ON en2.session_id = s2.id 
                    JOIN session_events se2 ON s2.id = se2.session_id
                    JOIN events e2 ON se2.event_id = e2.id
                    WHERE e2.project_id = e.project_id 
                    AND en2.status = 'active'
                )
            GROUP BY e.id, e.teacher_id, e.metadata, l.name, p.name
            ORDER BY e.time ASC
        };
        
        return $db->query($sql)->hashes->to_array;
    }
    
    # Find events that started more than 30 minutes ago with no attendance
    sub find_events_severely_overdue($class, $db) {
        my $sql = q{
            SELECT 
                e.id,
                e.teacher_id,
                e.metadata->>'title' as title,
                e.time as start_time,
                e.time + (e.duration || ' minutes')::interval as end_time,
                l.name as location_name,
                p.name as program_name,
                COUNT(en.id) as enrolled_count
            FROM events e
            JOIN locations l ON e.location_id = l.id
            JOIN projects p ON e.project_id = p.id
            LEFT JOIN session_events se ON e.id = se.event_id
            LEFT JOIN sessions s ON se.session_id = s.id
            LEFT JOIN enrollments en ON en.session_id = s.id AND en.status = 'active'
            WHERE 
                -- Event started more than 30 minutes ago
                e.time < now() - interval '30 minutes'
                -- And has no attendance records
                AND NOT EXISTS (
                    SELECT 1 FROM attendance_records ar 
                    WHERE ar.event_id = e.id
                )
                -- And has enrolled students
                AND EXISTS (
                    SELECT 1 FROM enrollments en2 
                    JOIN sessions s2 ON en2.session_id = s2.id 
                    JOIN session_events se2 ON s2.id = se2.session_id
                    JOIN events e2 ON se2.event_id = e2.id
                    WHERE e2.project_id = e.project_id 
                    AND en2.status = 'active'
                )
            GROUP BY e.id, e.teacher_id, e.metadata, l.name, p.name
            ORDER BY e.time ASC
        };
        
        return $db->query($sql)->hashes->to_array;
    }

    # Get upcoming events for enrolled children of a parent (moved from ParentDashboard controller)
    sub get_upcoming_for_parent($class, $db, $parent_id, $days = 7) {
        $db = $db->db if $db isa Registry::DAO;

        my $end_date = DateTime->now->add(days => $days)->epoch;

        my $sql = q{
            SELECT
                ev.id as event_id,
                ev.name as event_name,
                ev.start_time,
                ev.end_time,
                s.name as session_name,
                l.name as location_name,
                l.address as location_address,
                fm.child_name,
                ar.status as attendance_status
            FROM events ev
            JOIN sessions s ON ev.session_id = s.id
            JOIN enrollments e ON e.session_id = s.id
            JOIN family_members fm ON e.family_member_id = fm.id
            LEFT JOIN locations l ON ev.location_id = l.id
            LEFT JOIN attendance_records ar ON ar.event_id = ev.id
                AND ar.student_id = e.family_member_id
            WHERE fm.family_id = ?
            AND e.status IN ('active', 'pending')
            AND ev.start_time >= ?
            AND ev.start_time <= ?
            ORDER BY ev.start_time ASC
        };

        return $db->query($sql, $parent_id, time(), $end_date)->hashes->to_array;
    }

    # Get events for a specific date with attendance status (for admin dashboard)
    sub get_events_for_date($class, $db, $date) {
        my $date_obj = DateTime->from_ymd(split /-/, $date);
        my $start_time = $date_obj->epoch;
        my $end_time = $date_obj->add(days => 1)->epoch;

        my $sql = q{
            SELECT
                ev.id as event_id,
                ev.name as event_name,
                ev.start_time,
                ev.end_time,
                ev.capacity,
                s.name as session_name,
                p.name as program_name,
                l.name as location_name,
                COUNT(DISTINCT e.id) as enrolled_count,
                COUNT(DISTINCT ar.id) as attendance_taken,
                COUNT(DISTINCT CASE WHEN ar.status = 'present' THEN ar.id END) as present_count,
                COUNT(DISTINCT CASE WHEN ar.status = 'absent' THEN ar.id END) as absent_count
            FROM events ev
            JOIN sessions s ON ev.session_id = s.id
            JOIN projects p ON s.project_id = p.id
            LEFT JOIN locations l ON ev.location_id = l.id
            LEFT JOIN enrollments e ON s.id = e.session_id AND e.status = 'active'
            LEFT JOIN attendance_records ar ON ev.id = ar.event_id
            WHERE ev.start_time >= ? AND ev.start_time < ?
            GROUP BY ev.id, s.id, p.id, l.id
            ORDER BY ev.start_time ASC
        };

        my $results = $db->query($sql, $start_time, $end_time)->hashes->to_array;

        # Add attendance status
        for my $event (@$results) {
            if ($event->{attendance_taken} > 0) {
                $event->{attendance_status} = 'completed';
            } elsif ($event->{start_time} < time()) {
                $event->{attendance_status} = 'missing';
            } else {
                $event->{attendance_status} = 'pending';
            }
        }

        return $results;
    }

}

# Note: Pricing class has been replaced by Registry::DAO::PricingPlan
# to support multiple pricing tiers per session