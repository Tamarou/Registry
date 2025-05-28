package Registry::DAO::WorkflowSteps::RegisterTenant;
use 5.40.2;
use utf8;
use experimental qw(try);

use Object::Pad;
class Registry::DAO::WorkflowSteps::RegisterTenant :isa(Registry::DAO::WorkflowStep);

use Registry::DAO::Workflow;
use Carp qw(carp croak);
use Text::Unidecode qw(unidecode);

method process ( $db, $ ) {
    my ($workflow) = $self->workflow($db);
    my $run = $workflow->latest_run($db);

    my $profile = $run->data;

    # Extract user data in new format
    my $admin_user_data = {
        name => delete $profile->{admin_name},
        email => delete $profile->{admin_email},
        username => delete $profile->{admin_username},
        password => delete $profile->{admin_password},
        user_type => delete $profile->{admin_user_type} || 'admin',
    };
    
    my $team_members = delete $profile->{team_members} || [];
    
    # Convert to expected format for backward compatibility
    my $user_data = [$admin_user_data];
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

    # Generate subdomain slug from organization name
    if ($profile->{name} && !$profile->{slug}) {
        $profile->{slug} = $self->_generate_subdomain_slug($db, $profile->{name});
    }

    # Validate required billing fields
    $self->_validate_billing_info($profile);

    # first we wanna create the Registry user account for our tenant
    my $primary_user =
        Registry::DAO::User->find_or_create( $db, $user_data->[0] );
    unless ($primary_user) {
        croak 'Could not create primary user';
    }

    my $tenant = Registry::DAO::Tenant->create( $db, $profile );
    $db->query( 'SELECT clone_schema(dest_schema => ?)', $tenant->slug );

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

    # return the data to be stored in the workflow run
    return { tenant => $tenant->id };
}

method _generate_subdomain_slug($db, $name) {
    # Generate slug: lowercase, replace spaces/special chars with hyphens, remove multiple hyphens
    my $slug = lc($name);
    $slug = unidecode($slug);  # Convert unicode to ASCII
    $slug =~ s/[^a-z0-9\s-]//g;  # Remove special characters
    $slug =~ s/\s+/-/g;  # Replace spaces with hyphens
    $slug =~ s/-+/-/g;   # Remove multiple consecutive hyphens
    $slug =~ s/^-|-$//g; # Remove leading/trailing hyphens
    $slug = substr($slug, 0, 50);  # Limit length
    $slug = 'organization' if !$slug;  # Fallback if empty
    
    # Ensure uniqueness by checking existing tenants
    my $original_slug = $slug;
    my $counter = 1;
    
    while ($self->_slug_exists($db, $slug)) {
        $slug = "${original_slug}-${counter}";
        $counter++;
        last if $counter > 999;  # Prevent infinite loop
    }
    
    return $slug;
}

method _slug_exists($db, $slug) {
    my $result = $db->query('SELECT COUNT(*) FROM registry.tenants WHERE slug = ?', $slug);
    return $result->array->[0] > 0;
}

method _validate_billing_info($profile) {
    my @required_fields = qw(name billing_email billing_address billing_city billing_state billing_zip billing_country);
    my @missing = ();
    
    for my $field (@required_fields) {
        if (!$profile->{$field} || !length(_trim($profile->{$field}))) {
            push @missing, $field;
        }
    }
    
    if (@missing) {
        my $missing_str = join(', ', map { ucfirst($_) =~ s/_/ /gr } @missing);
        croak "Missing required billing information: $missing_str";
    }
    
    # Validate email format
    if ($profile->{billing_email} && $profile->{billing_email} !~ /\A[^@\s]+@[^@\s]+\z/) {
        croak "Invalid billing email format";
    }
    
    return 1;
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