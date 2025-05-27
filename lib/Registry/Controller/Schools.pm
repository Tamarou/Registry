use v5.34.0;
use Object::Pad;

class Registry::Controller::Schools :isa(Mojolicious::Controller) {
    use experimental qw(try);
    
    method show ($slug = $self->param('slug')) {
        my $dao = $self->app->dao;
        
        # Load location by slug
        my $location = Registry::DAO::Location->find($dao, { slug => $slug });
        
        unless ($location) {
            return $self->render(text => 'School not found', status => 404);
        }
        
        # Get active sessions at this location
        my $sessions = $self->_get_active_sessions_for_location($dao, $location->id);
        
        # Group sessions by project/program
        my $programs = $self->_group_sessions_by_program($dao, $sessions, $location->id);
        
        # Render the school page (no authentication required)
        $self->render(
            'schools/show',
            location => $location,
            programs => $programs,
            is_public => 1  # Flag for templates to know this is public
        );
    }
    
    method _get_active_sessions_for_location ($dao, $location_id) {
        # Get all sessions that:
        # 1. Have events at this location
        # 2. Are published (not draft or closed)
        # 3. Have not ended yet
        
        my $sql = q{
            SELECT DISTINCT s.*
            FROM sessions s
            JOIN session_events se ON se.session_id = s.id
            JOIN events e ON e.id = se.event_id
            WHERE e.location_id = ?
            AND s.status = 'published'
            AND (s.end_date IS NULL OR s.end_date >= CURRENT_DATE)
            ORDER BY s.start_date
        };
        
        my $results = $dao->query($sql, $location_id)->hashes;
        return [ map { Registry::DAO::Session->new(%$_) } @$results ];
    }
    
    method _group_sessions_by_program ($dao, $sessions, $location_id) {
        my %programs;
        
        for my $session (@$sessions) {
            # Get events for this session
            my $events = $session->events($dao);
            
            for my $event (@$events) {
                my $project = $event->project($dao);
                next unless $project;
                
                my $project_id = $project->id;
                $programs{$project_id} ||= {
                    project => $project,
                    sessions => []
                };
                
                # Calculate available spots for this session
                my $enrollments = Registry::DAO::Enrollment->find_all($dao, {
                    session_id => $session->id,
                    status => ['active', 'pending']
                });
                my $enrolled_count = @$enrollments;
                
                my $capacity = $event->capacity || 0;
                my $available_spots = $capacity > 0 ? $capacity - $enrolled_count : undef;
                
                # Get waitlist count
                my $waitlist_count = $session->waitlist_count($dao);
                
                # Get pricing info
                my $pricing_plans = $session->pricing_plans($dao);
                my $best_price = $session->get_best_price($dao, { date => time() });
                
                # Only add this session if it's for the current location
                next unless $event->location_id eq $location_id;
                
                push @{$programs{$project_id}{sessions}}, {
                    session => $session,
                    available_spots => $available_spots,
                    enrolled_count => $enrolled_count,
                    capacity => $capacity,
                    waitlist_count => $waitlist_count,
                    pricing_plans => $pricing_plans,
                    best_price => $best_price,
                    has_waitlist => $waitlist_count > 0,
                    is_full => defined $available_spots && $available_spots <= 0
                };
            }
        }
        
        # Return as array sorted by project name
        return [ 
            sort { $a->{project}->name cmp $b->{project}->name } 
            values %programs 
        ];
    }
}