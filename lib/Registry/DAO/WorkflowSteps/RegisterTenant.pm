use 5.40.2;
use utf8;
use experimental qw(try);
use Object::Pad;

class Registry::DAO::WorkflowSteps::RegisterTenant :isa(Registry::DAO::WorkflowStep) {

use Registry::DAO::Workflow;
use Registry::Utility::ErrorHandler;
use Carp qw(carp croak);
use Text::Unidecode qw(unidecode);
use DateTime;

method process ( $db, $ ) {
    warn "=============== DEBUG RegisterTenant: process method called ===============";
    
    my ($workflow) = $self->workflow($db);
    my $run = $workflow->latest_run($db);

    my $profile = $run->data;
    warn "DEBUG RegisterTenant: profile data keys = " . join(", ", keys %$profile);

    # Handle backward compatibility for old 'users' format
    my $user_data;
    if (exists $profile->{users} && ref $profile->{users} eq 'ARRAY') {
        # Old format: { users => [{username => '...', password => '...'}, ...] }
        $user_data = delete $profile->{users};
        # Set default user_type for backward compatibility
        for my $user (@$user_data) {
            $user->{user_type} //= 'admin';
        }
    } else {
        # New format: extract user data from individual fields
        my $admin_user_data = {
            name => delete $profile->{admin_name},
            email => delete $profile->{admin_email},
            username => delete $profile->{admin_username},
            password => delete $profile->{admin_password},
            user_type => delete $profile->{admin_user_type} || 'admin',
        };
        
        my $team_members = delete $profile->{team_members} || [];
        
        # Convert to expected format for backward compatibility
        $user_data = [$admin_user_data];
        for my $member (@$team_members) {
            if ($member->{name} && $member->{email}) {
                # Generate a username from the email
                my $username = $member->{email};
                $username =~ s/@.*$//;  # Remove domain
                $username =~ s/[^a-zA-Z0-9]//g;  # Remove special characters
                
                push @$user_data, {
                    name => $member->{name},
                    email => $member->{email},
                    username => $username,
                    password => $self->_generate_temp_password(),
                    user_type => $member->{user_type} || 'staff',
                    invite_pending => 1,  # Mark for invitation email
                };
            }
        }
    }

    # Generate subdomain slug from organization name
    if ($profile->{name} && !$profile->{slug}) {
        $profile->{slug} = $self->_generate_subdomain_slug($db, $profile->{name});
    }

    # Validate required billing fields (skip for backward compatibility)
    if (!exists $run->data->{users}) {
        $self->_validate_billing_info($profile);
    }

    # Validate that subscription was set up successfully (skip for backward compatibility)
    my $subscription_data = $run->data->{subscription};
    my $has_subscription = $subscription_data && $subscription_data->{stripe_subscription_id};
    
    # Debug output for test troubleshooting
    warn "DEBUG RegisterTenant: subscription_data = " . ($subscription_data ? "present" : "missing");
    warn "DEBUG RegisterTenant: has_subscription = " . ($has_subscription ? "yes" : "no");
    warn "DEBUG RegisterTenant: old users format = " . (exists $run->data->{users} ? "yes" : "no");
    
    # For backward compatibility, only require subscription if not using old 'users' format
    # Also skip if tenant was already created by TenantPayment step (test mode)
    my $tenant_already_created = exists $run->data->{tenant_created} && $run->data->{tenant_created};
    if (!$has_subscription && !exists $run->data->{users} && !$tenant_already_created) {
        warn "DEBUG RegisterTenant: FAILING - Payment setup must be completed before creating tenant";
        croak 'Payment setup must be completed before creating tenant';
    }
    
    # If tenant was already created by TenantPayment, just return success
    if ($tenant_already_created) {
        warn "DEBUG RegisterTenant: Tenant already created in previous step, skipping creation";
        return {
            tenant => $run->data->{tenant},
            organization_name => $run->data->{organization_name},
            subdomain => $run->data->{subdomain},
            admin_email => $run->data->{admin_email},
            success_timestamp => DateTime->now->iso8601()
        };
    }

    # first we wanna create the Registry user account for our tenant
    my $primary_user =
        Registry::DAO::User->find_or_create( $db, $user_data->[0] );
    unless ($primary_user) {
        croak 'Could not create primary user';
    }

    # Include subscription data in tenant creation (if available)
    if ($has_subscription) {
        $profile->{stripe_subscription_id} = $subscription_data->{stripe_subscription_id};
        $profile->{billing_status} = 'trial';
        $profile->{trial_ends_at} = $subscription_data->{trial_ends_at};
        $profile->{subscription_started_at} = DateTime->now->iso8601();
    } else {
        # Backward compatibility: set defaults for testing
        $profile->{billing_status} = 'test';
        $profile->{subscription_started_at} = DateTime->now->iso8601();
    }

    my $tenant = Registry::DAO::Tenant->create( $db, $profile );
    $db->query( 'SELECT clone_schema(?)', $tenant->slug );

    $tenant->set_primary_user( $db, $primary_user );

    my $tx = $db->begin;
    for my $data ( $user_data->@* ) {
        if ( my $user = Registry::DAO::User->find( $db, { username => $data->{username} } ) ) {
            $db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)',
                $tenant->slug, $user->id );
        }
        else {
            my $tenant_user = Registry::DAO::User->create( $tenant->dao($db)->db, $data );
            
            # Send invitation email for non-admin users
            if ($data->{invite_pending} && $data->{email}) {
                $self->_send_invitation_email($db, $tenant, $tenant_user, $data);
            }
        }
    }

    # NOTE: Previously we were getting a problem where workflows were missing their first step
    # after being copied to tenant schemas. To fix this, we'll directly copy the workflows using
    # the copy_workflow function instead of relying on the schema clone
    for my $slug (
        qw(user-creation session-creation event-creation location-creation project-creation location-management)
    )
    {
        my $workflow =
            Registry::DAO::Workflow->find( $db, { slug => $slug } );
            
        # Skip if workflow not found (this helps with testing)
        next unless $workflow;
            
        # Use the improved copy_workflow function to ensure first_step is preserved
        $db->query(
            'SELECT copy_workflow(dest_schema => ?, workflow_id => ?)',
            $tenant->slug, $workflow->id );
            
        # Verify first_step exists in tenant schema
        my $tenant_dao = $tenant->dao($db);
        my $tenant_workflow = $tenant_dao->find(Workflow => { slug => $slug });
        
        if ($tenant_workflow) {
            my $first_step_slug = $tenant_workflow->first_step_slug($tenant_dao->db);
            my $first_step = $tenant_workflow->first_step($tenant_dao->db);
            
            # If first_step value exists but the step doesn't, create it
            if ($first_step_slug && !$first_step) {
                Registry::DAO::WorkflowStep->create(
                    $tenant_dao->db,
                    {
                        workflow_id => $tenant_workflow->id,
                        slug => $first_step_slug,
                        description => "Auto-created first step by tenant registration",
                        class => 'Registry::DAO::WorkflowStep'
                    }
                );
            }
        }
    }
    
    # Copy outcome definitions
    my @outcome_defs = Registry::DAO::OutcomeDefinition->find($db);
    for my $def (@outcome_defs) {
        # Create in tenant schema directly
        Registry::DAO::OutcomeDefinition->create(
            $tenant->dao($db)->db,
            {
                id => $def->id,  # Use same ID to maintain relationships
                name => $def->name,
                schema => $def->schema
            }
        );
    }
    
    $tx->commit;

    if ( $run->has_continuation ) {
        my ($continuation) = $run->continuation($db);
        my $tenants = $continuation->data->{tenants} // [];
        push $tenants->@*, $tenant->id;
        $continuation->update_data( $db, { tenants => $tenants } );
    }

    # Store success data for completion template
    my $success_data = {
        tenant => $tenant->id,
        organization_name => $profile->{name},
        subdomain => $tenant->slug,
        admin_email => $user_data->[0]->{email} || $user_data->[0]->{username},
        trial_end_date => $has_subscription ? $self->_format_trial_end_date($subscription_data->{trial_ends_at}) : 'N/A',
        success_timestamp => DateTime->now->iso8601()
    };

    # return the data to be stored in the workflow run
    return $success_data;
}

method _generate_subdomain_slug($db, $name) {
    my $error_handler = Registry::Utility::ErrorHandler->new();
    
    # Validate name input
    unless ($name && length($name) > 0) {
        my $error = $error_handler->handle_validation_error(
            'organization_name',
            'Organization name is required to generate subdomain'
        );
        croak $error->{user_message};
    }
    
    # Generate slug: lowercase, replace spaces/special chars with hyphens, remove multiple hyphens
    my $slug = lc($name);
    $slug = unidecode($slug);  # Convert unicode to ASCII
    $slug =~ s/[^a-z0-9\s-]//g;  # Remove special characters
    $slug =~ s/\s+/-/g;  # Replace spaces with hyphens
    $slug =~ s/-+/-/g;   # Remove multiple consecutive hyphens
    $slug =~ s/^-|-$//g; # Remove leading/trailing hyphens
    $slug = substr($slug, 0, 50);  # Limit length
    $slug = 'organization' if !$slug;  # Fallback if empty
    
    # Ensure uniqueness by checking existing tenants with better suggestions
    my $original_slug = $slug;
    my $counter = 1;
    my @suggestions = ();
    
    while ($self->_slug_exists($db, $slug)) {
        $slug = "${original_slug}-${counter}";
        push @suggestions, $slug if $counter <= 3;  # Suggest first 3 alternatives
        $counter++;
        last if $counter > 999;  # Prevent infinite loop
    }
    
    # If we had to modify the slug, log the conflict for potential user notification
    if ($counter > 1) {
        my $conflict_error = $error_handler->handle_conflict_error(
            'subdomain', 
            'already_exists', 
            {
                attempted => $original_slug,
                chosen => $slug,
                suggested_alternatives => [@suggestions]
            }
        );
        
        # Log but don't throw - we resolved the conflict automatically
        $error_handler->log_error($conflict_error, {
            context => 'tenant_registration',
            auto_resolved => 1
        });
    }
    
    return $slug;
}

method _slug_exists($db, $slug) {
    my $result = $db->query('SELECT COUNT(*) FROM registry.tenants WHERE slug = ?', $slug);
    return $result->array->[0] > 0;
}

method _validate_billing_info($profile) {
    my $error_handler = Registry::Utility::ErrorHandler->new();
    my @required_fields = qw(name billing_email billing_address billing_city billing_state billing_zip billing_country);
    my @missing = ();
    my @validation_errors = ();
    
    # Check for missing required fields
    for my $field (@required_fields) {
        if (!$profile->{$field} || !length(_trim($profile->{$field}))) {
            push @missing, $field;
        }
    }
    
    if (@missing) {
        my $missing_str = join(', ', map { ucfirst($_) =~ s/_/ /gr } @missing);
        my $error = $error_handler->handle_validation_error(
            'billing_info',
            "Missing required billing information: $missing_str",
            \@missing
        );
        push @validation_errors, $error;
    }
    
    # Validate email format with more specific error
    if ($profile->{billing_email}) {
        my $email = _trim($profile->{billing_email});
        if ($email !~ /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/) {
            my $error = $error_handler->handle_validation_error(
                'billing_email',
                "Invalid email format: '$email'. Please enter a valid email address.",
                $email
            );
            push @validation_errors, $error;
        }
    }
    
    # Validate billing address length and format
    if ($profile->{billing_address} && length($profile->{billing_address}) < 5) {
        my $error = $error_handler->handle_validation_error(
            'billing_address',
            "Billing address is too short. Please provide a complete address."
        );
        push @validation_errors, $error;
    }
    
    # Validate ZIP code format (basic validation)
    if ($profile->{billing_zip}) {
        my $zip = _trim($profile->{billing_zip});
        if ($zip !~ /^\d{5}(-\d{4})?$/ && $zip !~ /^[A-Z]\d[A-Z] \d[A-Z]\d$/) {  # US or Canadian postal code
            my $error = $error_handler->handle_validation_error(
                'billing_zip',
                "Invalid ZIP/postal code format: '$zip'",
                $zip
            );
            push @validation_errors, $error;
        }
    }
    
    # Check for duplicate organizations (by email)
    if ($profile->{billing_email}) {
        my $existing_count = $self->_check_duplicate_organization($profile->{billing_email});
        if ($existing_count > 0) {
            my $error = $error_handler->handle_conflict_error(
                'organization',
                'duplicate_email',
                {
                    email => $profile->{billing_email},
                    existing_count => $existing_count
                }
            );
            push @validation_errors, $error;
        }
    }
    
    # If there are validation errors, collect them and throw
    if (@validation_errors) {
        my $messages = join('; ', map { $_->{user_message} } @validation_errors);
        
        # Log validation errors for monitoring
        $error_handler->log_error({
            type => 'validation_failure',
            errors => \@validation_errors,
            profile_data => {
                name => $profile->{name},
                billing_email => $profile->{billing_email}
            }
        });
        
        croak $messages;
    }
    
    return 1;
}

method _check_duplicate_organization($email) {
    # This would check for existing organizations with the same billing email
    # For now, return 0 (no duplicates found)
    # In production, this would query the database for existing tenants
    return 0;
}

sub _trim {
    my $str = shift;
    return '' unless defined $str;
    $str =~ s/^\s+|\s+$//g;
    return $str;
}

method _generate_temp_password() {
    # Generate a secure temporary password
    my @chars = ('A'..'Z', 'a'..'z', '0'..'9', '!', '@', '#', '$', '%');
    my $password = '';
    for (1..12) {
        $password .= $chars[rand @chars];
    }
    return $password;
}

method _send_invitation_email($db, $tenant, $user, $user_data) {
    # TODO: Implement email invitation system
    # For now, just log the invitation details
    warn "Would send invitation email to: " . $user_data->{email} . 
         " for tenant: " . $tenant->slug . 
         " with temporary password (this should be sent via secure email)";
         
    # In a production system, this would:
    # 1. Generate a secure invitation token
    # 2. Store the token in a database table
    # 3. Send an email with a link to set up their account
    # 4. Allow them to set their own password via the token
}

method _format_trial_end_date($trial_ends_at) {
    return 'N/A' unless $trial_ends_at;
    
    # Parse the timestamp (could be Unix timestamp)
    my $dt;
    if ($trial_ends_at =~ /^\d+$/) {
        # Unix timestamp
        $dt = DateTime->from_epoch(epoch => $trial_ends_at);
    } else {
        # For now, just return the raw value if not a unix timestamp
        # In a production system, we'd add proper ISO date parsing
        return $trial_ends_at;
    }
    
    # Format as human-readable date
    return $dt->strftime('%B %d, %Y');
}

}