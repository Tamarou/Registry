use 5.40.2;
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
        
        # Get filter parameters
        my $filters = {
            min_age => $self->param('min_age'),
            max_age => $self->param('max_age'),
            grade => $self->param('grade'),
            start_date => $self->param('start_date'),
            program_type => $self->param('program_type'),
        };
        
        # Get active sessions at this location
        my $sessions = $self->_get_active_sessions_for_location($dao, $location->id, $filters);
        
        # Group sessions by project/program
        my $programs = $self->_group_sessions_by_program($dao, $sessions, $location->id);
        
        # Apply visual enhancements to programs
        $self->_enhance_program_display($dao, $programs);
        
        # Check if this is an HTMX request
        if ($self->req->headers->header('HX-Request')) {
            # Return only the programs section for HTMX updates
            return $self->render(
                'schools/_programs',
                location => $location,
                programs => $programs,
                filters => $filters
            );
        }
        
        # Render the full school page (no authentication required)
        $self->render(
            'schools/show',
            location => $location,
            programs => $programs,
            filters => $filters,
            is_public => 1  # Flag for templates to know this is public
        );
    }
    
    method _get_active_sessions_for_location ($dao, $location_id, $filters = {}) {
        # Build SQL with filters
        my @where_clauses = (
            'e.location_id = ?',
            "s.status = 'published'",
            '(s.end_date IS NULL OR s.end_date >= CURRENT_DATE)'
        );
        my @params = ($location_id);
        
        # Add age filters
        if ($filters->{min_age}) {
            push @where_clauses, '(e.max_age IS NULL OR e.max_age >= ?)';
            push @params, $filters->{min_age};
        }
        if ($filters->{max_age}) {
            push @where_clauses, '(e.min_age IS NULL OR e.min_age <= ?)';
            push @params, $filters->{max_age};
        }
        
        # Add start date filter
        if ($filters->{start_date}) {
            push @where_clauses, 's.start_date >= ?';
            push @params, $filters->{start_date};
        }
        
        # Add program type filter
        if ($filters->{program_type}) {
            push @where_clauses, 'p.slug = ?';
            push @params, $filters->{program_type};
        }
        
        my $where = join(' AND ', @where_clauses);
        
        my $sql = qq{
            SELECT DISTINCT s.*, p.slug as program_type_slug
            FROM sessions s
            JOIN session_events se ON se.session_id = s.id
            JOIN events e ON e.id = se.event_id
            JOIN projects proj ON proj.id = e.project_id
            LEFT JOIN program_types p ON p.slug = proj.program_type_slug
            WHERE $where
            ORDER BY s.start_date
        };
        
        my $results = $dao->query($sql, @params)->hashes;
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
    
    method _enhance_program_display ($dao, $programs) {
        for my $program (@$programs) {
            for my $session_info (@{$program->{sessions}}) {
                my $session = $session_info->{session};
                
                # Calculate fill percentage
                if (defined $session_info->{capacity} && $session_info->{capacity} > 0) {
                    my $fill_percentage = ($session_info->{enrolled_count} / $session_info->{capacity}) * 100;
                    $session_info->{fill_percentage} = $fill_percentage;
                    $session_info->{is_filling_up} = $fill_percentage >= 80;
                }
                
                # Check for early bird pricing
                my $pricing_plans = $session_info->{pricing_plans} || [];
                for my $plan (@$pricing_plans) {
                    if ($plan->plan_type eq 'early_bird' && $plan->is_early_bird_available) {
                        $session_info->{has_early_bird} = 1;
                        $session_info->{early_bird_price} = $plan->amount;
                        $session_info->{early_bird_expires} = $plan->requirements->{early_bird_cutoff_date};
                        last;
                    }
                }
                
                # Get program type info
                if ($program->{project}->program_type_slug) {
                    my $program_type = Registry::DAO::ProgramType->find_by_slug(
                        $dao, 
                        $program->{project}->program_type_slug
                    );
                    $session_info->{program_type} = $program_type if $program_type;
                }
            }
        }
    }
}