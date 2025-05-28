package Registry::DAO::WorkflowSteps::RegisterTenant;
use 5.40.2;
use utf8;
use experimental qw(try);

use Object::Pad;
class Registry::DAO::WorkflowSteps::RegisterTenant :isa(Registry::DAO::WorkflowStep);

use Registry::DAO::Workflow;
use Carp qw(carp croak);

method process ( $db, $ ) {
    my ($workflow) = $self->workflow($db);
    my $run = $workflow->latest_run($db);

    my $profile = $run->data;

    my $user_data = delete $profile->{users};

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
        if ( my $user = Registry::DAO::User->find( $db, $data ) ) {
            $db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)',
                $tenant->slug, $user->id );
        }
        else {
            Registry::DAO::User->create( $tenant->dao($db)->db, $data );
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