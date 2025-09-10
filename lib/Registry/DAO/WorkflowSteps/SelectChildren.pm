use 5.40.2;
use utf8;
use experimental qw(try);
use Object::Pad;

class Registry::DAO::WorkflowSteps::SelectChildren :isa(Registry::DAO::WorkflowStep) {
    use Carp qw( croak );
    use Mojo::JSON qw( decode_json encode_json );
    
    method process ($db, $form_data) {
        my $workflow = $self->workflow($db);
        my $run = $workflow->latest_run($db);
        
        # Get user_id from run data (set by account-check step)
        my $user_id = $run->data->{user_id};
        unless ($user_id) {
            return {
                stay => 1,
                errors => ['User not logged in. Please go back to account setup.']
            };
        }
        
        my $action = $form_data->{action} || '';
        
        if ($action eq 'add_child') {
            # Add a new child to the family
            my $child_data = {
                child_name => $form_data->{new_child_name},
                birth_date => $form_data->{new_birth_date},
                grade => $form_data->{new_grade},
                medical_info => {
                    allergies => $form_data->{new_allergies} ? 
                        [split /\s*,\s*/, $form_data->{new_allergies}] : [],
                    medications => $form_data->{new_medications} ? 
                        [split /\s*,\s*/, $form_data->{new_medications}] : [],
                    notes => $form_data->{new_medical_notes} || '',
                },
                emergency_contact => {
                    name => $form_data->{new_emergency_name},
                    phone => $form_data->{new_emergency_phone},
                    relationship => $form_data->{new_emergency_relationship},
                },
            };
            
            # Validate child data
            my $errors = $self->_validate_child_data($child_data);
            if ($errors) {
                return {
                    stay => 1,
                    errors => $errors,
                };
            }
            
            # Add the child
            try {
                require Registry::DAO::Family;
                my $child = Registry::DAO::Family->add_child($db, $user_id, $child_data);
                
                # If HTMX request, return just the new child row
                if ($form_data->{'HX-Request'}) {
                    return {
                        htmx_response => 1,
                        child => $child,
                    };
                }
            }
            catch ($e) {
                return {
                    stay => 1,
                    errors => ["Failed to add child: $e"]
                };
            }
            
            # Stay on page after adding child
            return { stay => 1 };
        }
        elsif ($action eq 'continue') {
            # Process selected children
            my @selected_child_ids;
            
            # Collect selected child IDs from checkboxes
            for my $key (keys %$form_data) {
                if ($key =~ /^child_(\w+)$/ && $form_data->{$key}) {
                    push @selected_child_ids, $1;
                }
            }
            
            unless (@selected_child_ids) {
                return {
                    stay => 1,
                    errors => ['Please select at least one child to enroll']
                };
            }
            
            # Store selected children in run data
            $run->update_data($db, {
                selected_child_ids => \@selected_child_ids,
                enrollment_count => scalar(@selected_child_ids),
            });
            
            # Move to next step
            return { next_step => 'session-selection' };
        }
        else {
            # First visit or refresh - just display the page
            return { stay => 1 };
        }
    }
    
    method _validate_child_data ($child_data) {
        my @errors;
        
        push @errors, 'Child name is required' 
            unless $child_data->{child_name};
        push @errors, 'Birth date is required' 
            unless $child_data->{birth_date};
        push @errors, 'Emergency contact name is required' 
            unless $child_data->{emergency_contact}{name};
        push @errors, 'Emergency contact phone is required' 
            unless $child_data->{emergency_contact}{phone};
        
        # Validate birth date format
        if ($child_data->{birth_date} && 
            $child_data->{birth_date} !~ /^\d{4}-\d{2}-\d{2}$/) {
            push @errors, 'Birth date must be in YYYY-MM-DD format';
        }
        
        return @errors ? \@errors : undef;
    }
    
    method validate ($db, $form_data) {
        my $action = $form_data->{action} || '';
        
        if ($action eq 'add_child') {
            return $self->_validate_child_data({
                child_name => $form_data->{new_child_name},
                birth_date => $form_data->{new_birth_date},
                emergency_contact => {
                    name => $form_data->{new_emergency_name},
                    phone => $form_data->{new_emergency_phone},
                },
            });
        }
        elsif ($action eq 'continue') {
            # Check if at least one child is selected
            my $has_selection = 0;
            for my $key (keys %$form_data) {
                if ($key =~ /^child_\w+$/ && $form_data->{$key}) {
                    $has_selection = 1;
                    last;
                }
            }
            
            unless ($has_selection) {
                return ['Please select at least one child to enroll'];
            }
        }
        
        return;
    }
}