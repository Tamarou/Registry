use 5.40.2;
use utf8;
use experimental qw(try);
use Object::Pad;

class Registry::DAO::WorkflowSteps::AccountCheck :isa(Registry::DAO::WorkflowStep) {
    use Carp qw( croak );
    
    method process ($db, $form_data) {
        my $workflow = $self->workflow($db);
        my $run = $workflow->latest_run($db);
        
        # Check if user selected an action
        my $action = $form_data->{action} || '';
        
        if ($action eq 'login') {
            # User chose to login - process login
            my $username = $form_data->{username};
            my $password = $form_data->{password};
            
            if ($username && $password) {
                # Verify credentials
                my $user = Registry::DAO::User->find($db, { username => $username });
                
                if ($user && $user->check_password($password)) {
                    # Login successful - store user_id in run data
                    $run->update_data($db, { 
                        user_id => $user->id,
                        user_name => $user->name,
                        user_email => $user->email,
                    });
                    
                    # Move to next step
                    return { next_step => 'select-children' };
                }
                else {
                    # Login failed
                    return {
                        stay => 1,
                        errors => ['Invalid username or password']
                    };
                }
            }
            else {
                # Missing credentials
                return {
                    stay => 1,
                    errors => ['Please enter both username and password']
                };
            }
        }
        elsif ($action eq 'create_account') {
            # User chose to create account - start continuation to user-creation workflow
            
            # Store current run data that we want to preserve
            my $enrollment_data = {
                session_id => $form_data->{session_id} || $run->data->{session_id},
                location_id => $form_data->{location_id} || $run->data->{location_id},
                program_id => $form_data->{program_id} || $run->data->{program_id},
            };
            
            $run->update_data($db, $enrollment_data);
            
            # Start continuation to user-creation workflow
            return {
                continuation => 'user-creation',
                continuation_data => {
                    return_to => 'summer-camp-registration-enhanced',
                    return_step => 'account-check',
                    enrollment_data => $enrollment_data,
                }
            };
        }
        elsif ($action eq 'continue_logged_in') {
            # User is already logged in (returning from continuation or already had session)
            my $user_id = $form_data->{user_id} || $run->data->{user_id};
            
            if ($user_id) {
                # Verify user still exists
                my $user = Registry::DAO::User->find($db, { id => $user_id });
                
                if ($user) {
                    # Store/update user info in run data
                    $run->update_data($db, {
                        user_id => $user->id,
                        user_name => $user->name,
                        user_email => $user->email,
                    });
                    
                    # Move to next step
                    return { next_step => 'select-children' };
                }
            }
            
            # No valid user - stay on this step
            return { stay => 1 };
        }
        else {
            # First visit or returning from continuation
            
            # Check if we're returning from user creation
            if ($run->has_continuation) {
                my $continuation = $run->continuation($db);
                my $cont_data = $continuation->data;
                
                # Check if user was created
                if ($cont_data->{user_id}) {
                    # User was created - store info and continue
                    $run->update_data($db, {
                        user_id => $cont_data->{user_id},
                        user_name => $cont_data->{user_name},
                        user_email => $cont_data->{user_email},
                        # Restore enrollment data
                        %{$cont_data->{enrollment_data} || {}}
                    });
                    
                    # Mark continuation as complete
                    $continuation->complete($db);
                    
                    # Move to next step
                    return { next_step => 'select-children' };
                }
            }
            
            # Check if user is already logged in (session)
            # This would normally check the controller's session
            # For now, we'll stay on this step to show options
            return { stay => 1 };
        }
    }
    
    method validate ($db, $form_data) {
        my @errors;
        
        my $action = $form_data->{action} || '';
        
        if ($action eq 'login') {
            push @errors, 'Username is required' unless $form_data->{username};
            push @errors, 'Password is required' unless $form_data->{password};
        }
        
        return @errors ? \@errors : undef;
    }
}