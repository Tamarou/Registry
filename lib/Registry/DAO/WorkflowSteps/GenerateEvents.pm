package Registry::DAO::WorkflowSteps::GenerateEvents;
use 5.40.2;
use warnings;
use experimental 'signatures', 'try', 'builtin';

use Object::Pad;
class Registry::DAO::WorkflowSteps::GenerateEvents :isa(Registry::DAO::WorkflowStep);

use Registry::DAO::Event;
use Registry::DAO::Session;
use Mojo::JSON qw(encode_json);
use DateTime;

method process ($db, $form_data) {
    my $workflow = $self->workflow($db);
    my $run = $workflow->latest_run($db);
    my $data = $run->data;
    
    # If form was submitted (confirmation)
    if ($form_data->{confirm_generation}) {
        my $generation_params = $form_data->{generation_params};
        
        # Validate required parameters
        unless ($generation_params->{start_date} && $generation_params->{duration_weeks}) {
            return {
                next_step => $self->id,
                errors => ['Start date and duration are required'],
                data => $self->prepare_data($db)
            };
        }
        
        # Generate events for each configured location
        my @created_sessions;
        for my $location (@{$data->{configured_locations}}) {
            my $session_data = $self->create_session_for_location(
                $db, $data, $location, $generation_params
            );
            
            if ($session_data->{error}) {
                return {
                    next_step => $self->id,
                    errors => [$session_data->{error}],
                    data => $self->prepare_data($db)
                };
            }
            
            push @created_sessions, $session_data;
        }
        
        # Store results in workflow data
        $run->data->{created_sessions} = \@created_sessions;
        $run->save($db);
        
        return { next_step => 'complete' };
    }
    
    # Show generation form
    return {
        next_step => $self->id,
        data => $self->prepare_data($db)
    };
}

method create_session_for_location ($db, $project_data, $location, $params) {
    try {
        # Create session for this location
        my $session = Registry::DAO::Session->create($db, {
            project_id => $project_data->{project_id},
            location_id => $location->{id},
            name => "$project_data->{project_name} at $location->{name}",
            description => $project_data->{project_description},
            capacity => $location->{capacity},
            status => 'upcoming',
            metadata => encode_json({
                program_assignment => 'generated',
                schedule => $location->{schedule},
                pricing_override => $location->{pricing_override},
                notes => $location->{notes}
            })
        });
        
        # Generate events based on pattern
        my @events = $self->generate_events_for_session(
            $db, $session, $location, $params
        );
        
        return {
            session_id => $session->id,
            session_name => $session->name,
            location_name => $location->{name},
            events_created => scalar(@events),
            event_ids => [map { $_->id } @events]
        };
    } catch ($error) {
        return { error => "Failed to create session for $location->{name}: $error" };
    }
}

method generate_events_for_session ($db, $session, $location, $params) {
    my @events;
    my $start_date = DateTime->from_epoch(epoch => $params->{start_date});
    my $duration_weeks = $params->{duration_weeks};
    my $schedule = $location->{schedule};
    
    # Generate events for each day in the schedule
    for my $week (0 .. $duration_weeks - 1) {
        for my $day_name (keys %$schedule) {
            my $day_offset = $self->day_name_to_offset($day_name);
            next unless defined $day_offset;
            
            my $event_date = $start_date->clone->add(
                weeks => $week,
                days => $day_offset
            );
            
            my $time_str = $schedule->{$day_name};
            my ($hour, $minute) = split ':', $time_str;
            $event_date->set_hour($hour)->set_minute($minute);
            
            my $event = Registry::DAO::Event->create($db, {
                session_id => $session->id,
                date => $event_date->strftime('%Y-%m-%d'),
                start_time => $event_date->strftime('%H:%M'),
                end_time => $event_date->clone->add(hours => 1)->strftime('%H:%M'), # Default 1 hour duration
                status => 'scheduled',
                metadata => encode_json({
                    generated_from => 'location_assignment',
                    week_number => $week + 1,
                    day_name => $day_name
                })
            });
            
            push @events, $event;
        }
    }
    
    return @events;
}

method day_name_to_offset ($day_name) {
    my %day_offsets = (
        monday => 0,
        tuesday => 1,
        wednesday => 2,
        thursday => 3,
        friday => 4,
        saturday => 5,
        sunday => 6
    );
    
    return $day_offsets{lc($day_name)};
}

method prepare_data ($db) {
    my $workflow = $self->workflow($db);
    my $run = $workflow->latest_run($db);
    my $data = $run->data;
    
    return {
        project_name => $data->{project_name},
        configured_locations => $data->{configured_locations},
        total_locations => scalar(@{$data->{configured_locations} || []})
    };
}

method template { 'program-location-assignment/generate-events' }

1;