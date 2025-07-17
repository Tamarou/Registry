use 5.40.2;
use Object::Pad;

class Registry::DAO::Event :isa(Registry::DAO::Object) {
    use Carp         qw( carp );
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
        return undef unless $project_id;
        
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
}

# Note: Pricing class has been replaced by Registry::DAO::PricingPlan
# to support multiple pricing tiers per session