package Registry::DAO::Schedule;
use 5.40.2;
use warnings;
use experimental 'signatures', 'try', 'builtin';

use Object::Pad;
class Registry::DAO::Schedule :isa(Registry::DAO::Object);

use DateTime;
use Registry::DAO::Event;
use Registry::DAO::Location;
use Registry::DAO::User;
use Mojo::JSON qw(decode_json);

method table { 'events' } # We work primarily with events for scheduling

method get_teacher_schedule ($db, $teacher_id, $start_date = undef, $end_date = undef) {
    $start_date //= DateTime->now->strftime('%Y-%m-%d');
    $end_date //= DateTime->now->add(weeks => 4)->strftime('%Y-%m-%d');
    
    my $events = $db->select('events', '*', {
        teacher_id => $teacher_id,
        -and => [
            \'time::date >= ?', $start_date,
            \'time::date <= ?', $end_date
        ]
    }, { -asc => 'time' })->hashes;
    
    return $events->map(sub {
        my $event = $_;
        # Add location info for travel time calculations
        my $location = $db->select('locations', ['name', 'latitude', 'longitude'], 
                                  { id => $event->{location_id} })->hash;
        $event->{location} = $location;
        return $event;
    })->to_array;
}

method check_conflicts ($db, $teacher_id, $proposed_event) {
    my $conflicts = [];
    my $travel_time_minutes = $self->get_travel_time_config($db);
    
    # Get teacher's existing schedule around the proposed time
    my $check_start = DateTime->from_epoch(epoch => $proposed_event->{time})
                             ->subtract(minutes => $travel_time_minutes + $proposed_event->{duration});
    my $check_end = DateTime->from_epoch(epoch => $proposed_event->{time})
                           ->add(minutes => $proposed_event->{duration} + $travel_time_minutes);
    
    my $existing_events = $db->select('events', '*', {
        teacher_id => $teacher_id,
        -and => [
            \'time >= ?', $check_start->epoch,
            \'time <= ?', $check_end->epoch
        ]
    })->hashes;
    
    for my $event ($existing_events->each) {
        my $event_start = DateTime->from_epoch(epoch => $event->{time});
        my $event_end = $event_start->clone->add(minutes => $event->{duration});
        my $proposed_start = DateTime->from_epoch(epoch => $proposed_event->{time});
        my $proposed_end = $proposed_start->clone->add(minutes => $proposed_event->{duration});
        
        # Check for direct time overlap
        if ($self->times_overlap($event_start, $event_end, $proposed_start, $proposed_end)) {
            push @$conflicts, {
                type => 'time_overlap',
                event_id => $event->{id},
                event_start => $event_start->iso8601,
                event_end => $event_end->iso8601,
                message => "Direct time conflict with existing event"
            };
            next;
        }
        
        # Check for travel time conflicts if different locations
        if ($event->{location_id} ne $proposed_event->{location_id}) {
            my $travel_needed = $self->calculate_travel_time($db, 
                $event->{location_id}, $proposed_event->{location_id});
            
            # Check if there's enough time between events for travel
            my $time_between;
            if ($event_end <= $proposed_start) {
                # Existing event ends before proposed starts
                $time_between = $proposed_start->subtract_datetime($event_end)->in_units('minutes');
            } else {
                # Proposed event ends before existing starts  
                $time_between = $event_start->subtract_datetime($proposed_end)->in_units('minutes');
            }
            
            if ($time_between < $travel_needed) {
                push @$conflicts, {
                    type => 'travel_time',
                    event_id => $event->{id},
                    travel_time_needed => $travel_needed,
                    time_available => $time_between,
                    message => "Insufficient travel time between locations"
                };
            }
        }
    }
    
    return $conflicts;
}

method times_overlap ($start1, $end1, $start2, $end2) {
    return !($end1 <= $start2 || $end2 <= $start1);
}

method calculate_travel_time ($db, $location1_id, $location2_id) {
    # If same location, no travel time needed
    return 0 if $location1_id eq $location2_id;
    
    # Get travel time configuration
    my $default_travel_time = $self->get_travel_time_config($db);
    
    # Get location coordinates for distance calculation
    my $loc1 = $db->select('locations', ['latitude', 'longitude'], 
                          { id => $location1_id })->hash;
    my $loc2 = $db->select('locations', ['latitude', 'longitude'], 
                          { id => $location2_id })->hash;
    
    # If both locations have coordinates, calculate distance-based travel time
    if ($loc1->{latitude} && $loc1->{longitude} && 
        $loc2->{latitude} && $loc2->{longitude}) {
        
        my $distance = $self->calculate_distance(
            $loc1->{latitude}, $loc1->{longitude},
            $loc2->{latitude}, $loc2->{longitude}
        );
        
        # Assume average speed of 30 mph (0.5 miles per minute)
        # Add 5 minutes buffer for parking/setup
        return int($distance / 0.5) + 5;
    }
    
    # Default travel time if no coordinates available
    return $default_travel_time;
}

method calculate_distance ($lat1, $lon1, $lat2, $lon2) {
    # Haversine formula for great-circle distance
    my $R = 3959; # Earth's radius in miles
    my $dLat = ($lat2 - $lat1) * (3.14159265359 / 180);
    my $dLon = ($lon2 - $lon1) * (3.14159265359 / 180);
    
    my $a = sin($dLat/2) * sin($dLat/2) +
            cos($lat1 * (3.14159265359 / 180)) * cos($lat2 * (3.14159265359 / 180)) *
            sin($dLon/2) * sin($dLon/2);
    my $c = 2 * atan2(sqrt($a), sqrt(1-$a));
    
    return $R * $c;
}

method get_travel_time_config ($db) {
    # Check for tenant-specific configuration
    my $config = $db->select('tenant_profiles', ['travel_time_minutes'], 
                            {}, { limit => 1 })->hash;
    
    return $config->{travel_time_minutes} // 15; # Default 15 minutes
}

method assign_teacher ($db, $event_id, $teacher_id, $options = {}) {
    my $event = Registry::DAO::Event->new(id => $event_id)->load($db);
    unless ($event) {
        return { 
            success => 0, 
            error => "Event not found: $event_id" 
        };
    }
    
    # Check for conflicts unless override is specified
    unless ($options->{override_conflicts}) {
        my $proposed_event = {
            time => $event->time,
            duration => $event->duration,
            location_id => $event->location_id
        };
        
        my $conflicts = $self->check_conflicts($db, $teacher_id, $proposed_event);
        
        if (@$conflicts) {
            return {
                success => 0,
                error => "Teacher assignment conflicts detected",
                conflicts => $conflicts
            };
        }
    }
    
    # Update event with teacher assignment
    try {
        $db->update('events', { teacher_id => $teacher_id }, { id => $event_id });
        
        # Also update session_teachers if this event belongs to a session
        my $session_event = $db->select('session_events', ['session_id'], 
                                       { event_id => $event_id })->hash;
        if ($session_event) {
            # Add teacher to session if not already assigned
            $db->query(
                'INSERT INTO session_teachers (session_id, teacher_id) 
                 VALUES (?, ?) ON CONFLICT (session_id, teacher_id) DO NOTHING',
                $session_event->{session_id}, $teacher_id
            );
        }
        
        return { 
            success => 1, 
            message => "Teacher assigned successfully" 
        };
    } catch ($error) {
        return { 
            success => 0, 
            error => "Failed to assign teacher: $error" 
        };
    }
}

method get_available_teachers ($db, $proposed_event) {
    # Get all teachers (users with teacher role)
    my $all_teachers = $db->select('users', ['id', 'username'], 
                                  { user_type => 'staff' })->hashes;
    
    my $available_teachers = [];
    
    for my $teacher ($all_teachers->each) {
        my $conflicts = $self->check_conflicts($db, $teacher->{id}, $proposed_event);
        
        if (!@$conflicts) {
            push @$available_teachers, $teacher;
        } else {
            # Include teacher with conflict information for UI decision
            $teacher->{conflicts} = $conflicts;
            push @$available_teachers, $teacher;
        }
    }
    
    return $available_teachers;
}

method get_schedule_grid ($db, $start_date, $end_date, $location_ids = []) {
    my $where = {
        -and => [
            \'time::date >= ?', $start_date,
            \'time::date <= ?', $end_date
        ]
    };
    
    if (@$location_ids) {
        $where->{location_id} = { -in => $location_ids };
    }
    
    my $events = $db->select('events', '*', $where, { -asc => 'time' })->hashes;
    
    # Group events by teacher and day for grid display
    my $grid = {};
    for my $event ($events->each) {
        my $date = DateTime->from_epoch(epoch => $event->{time})->strftime('%Y-%m-%d');
        my $teacher_id = $event->{teacher_id};
        
        $grid->{$teacher_id} //= {};
        $grid->{$teacher_id}->{$date} //= [];
        push @{$grid->{$teacher_id}->{$date}}, $event;
    }
    
    return $grid;
}

1;