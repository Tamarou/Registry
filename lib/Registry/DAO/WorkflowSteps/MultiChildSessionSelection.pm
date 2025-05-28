use 5.40.2;
use utf8;
use experimental qw(try);
use Object::Pad;

class Registry::DAO::WorkflowSteps::MultiChildSessionSelection :isa(Registry::DAO::WorkflowStep) {
    use Carp qw( croak );
    
    method process ($db, $form_data) {
        my $workflow = $self->workflow($db);
        my $run = $workflow->latest_run($db);
        
        # Get selected children from run data
        my $selected_child_ids = $run->data->{selected_child_ids} || [];
        unless (@$selected_child_ids) {
            return {
                stay => 1,
                errors => ['No children selected. Please go back to child selection.']
            };
        }
        
        # Get location and program info from run data
        my $location_id = $run->data->{location_id};
        my $program_id = $run->data->{program_id};
        
        # Load children and check program type rules
        require Registry::DAO::Family;
        require Registry::DAO::ProgramType;
        
        my @children;
        for my $child_id (@$selected_child_ids) {
            my $child = Registry::DAO::FamilyMember->find($db, { id => $child_id });
            push @children, $child if $child;
        }
        
        # Get program type to check rules
        my $program;
        my $program_type;
        if ($program_id) {
            $program = Registry::DAO::Project->find($db, { id => $program_id });
            if ($program && $program->program_type_slug) {
                $program_type = Registry::DAO::ProgramType->find_by_slug(
                    $db, 
                    $program->program_type_slug
                );
            }
        }
        
        my $action = $form_data->{action} || '';
        
        if ($action eq 'select_sessions') {
            # Process session selections
            my %selections;  # child_id => session_id
            my @errors;
            
            # Collect selections from form
            for my $key (keys %$form_data) {
                if ($key =~ /^session_for_(\w+)$/) {
                    my $child_id = $1;
                    my $session_id = $form_data->{$key};
                    
                    if ($session_id && $session_id ne 'none') {
                        $selections{$child_id} = $session_id;
                    }
                }
            }
            
            # Validate selections
            for my $child (@children) {
                unless ($selections{$child->id}) {
                    push @errors, "Please select a session for " . $child->child_name;
                }
            }
            
            # Check program type rules
            if ($program_type && $program_type->same_session_for_siblings && @children > 1) {
                # All children must be in the same session
                my @unique_sessions = keys %{{ map { $_ => 1 } values %selections }};
                if (@unique_sessions > 1) {
                    push @errors, "All siblings must be enrolled in the same session for " . 
                                  $program_type->name . " programs";
                }
            }
            
            if (@errors) {
                return {
                    stay => 1,
                    errors => \@errors,
                };
            }
            
            # Store selections in run data
            my @enrollment_items;
            for my $child_id (keys %selections) {
                push @enrollment_items, {
                    child_id => $child_id,
                    session_id => $selections{$child_id},
                };
            }
            
            $run->update_data($db, {
                enrollment_items => \@enrollment_items,
                session_selections => \%selections,
            });
            
            # Move to payment step
            return { next_step => 'payment' };
        }
        else {
            # First visit - display available sessions
            return { stay => 1 };
        }
    }
    
    method validate ($db, $form_data) {
        my $action = $form_data->{action} || '';
        
        if ($action eq 'select_sessions') {
            my @errors;
            my $has_selection = 0;
            
            for my $key (keys %$form_data) {
                if ($key =~ /^session_for_\w+$/ && 
                    $form_data->{$key} && 
                    $form_data->{$key} ne 'none') {
                    $has_selection = 1;
                    last;
                }
            }
            
            push @errors, 'Please select at least one session' unless $has_selection;
            
            return @errors ? \@errors : undef;
        }
        
        return undef;
    }
    
    method get_available_sessions ($db, $location_id, $program_id, $child) {
        # Get sessions that:
        # 1. Are at the specified location
        # 2. Match the program
        # 3. Are age-appropriate for the child
        # 4. Have available capacity
        
        my $sql = q{
            SELECT DISTINCT s.*
            FROM sessions s
            JOIN session_events se ON se.session_id = s.id
            JOIN events e ON e.id = se.event_id
            WHERE e.location_id = ?
            AND e.project_id = ?
            AND s.status = 'published'
            AND (e.min_age IS NULL OR e.min_age <= ?)
            AND (e.max_age IS NULL OR e.max_age >= ?)
            AND s.end_date >= CURRENT_DATE
            ORDER BY s.start_date
        };
        
        my $child_age = $child->age();
        my $results = $db->query($sql, $location_id, $program_id, $child_age, $child_age)->hashes;
        
        my @available_sessions;
        for my $row (@$results) {
            my $session = Registry::DAO::Session->new(%$row);
            
            # Check capacity
            my $capacity = $session->total_capacity($db) || 0;
            my $enrolled = $db->select('enrollments', 'COUNT(*)', {
                session_id => $session->id,
                status => ['active', 'pending']
            })->array->[0];
            
            if (!$capacity || $enrolled < $capacity) {
                push @available_sessions, {
                    session => $session,
                    available_spots => $capacity ? $capacity - $enrolled : undef,
                    is_full => 0,
                };
            }
        }
        
        return \@available_sessions;
    }
}