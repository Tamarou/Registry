package Registry::DAO::WorkflowSteps::SelectProgram;
use 5.40.2;
use warnings;
use experimental 'signatures', 'try', 'builtin';

use Object::Pad;
class Registry::DAO::WorkflowSteps::SelectProgram :isa(Registry::DAO::WorkflowStep);

use Registry::DAO::Project;

method process ($db, $form_data) {
    my $workflow = $self->workflow($db);
    my $run = $workflow->latest_run($db);
    
    # If form was submitted
    if ($form_data->{project_id}) {
        # Validate project exists
        my $project = Registry::DAO::Project->new(
            id => $form_data->{project_id}
        )->load($db);
        
        unless ($project) {
            return {
                next_step => $self->id,
                errors => ['Invalid program selected'],
                data => $self->prepare_data($db)
            };
        }
        
        # Store selection in workflow data
        $run->data->{project_id} = $project->id;
        $run->data->{project_name} = $project->name;
        $run->data->{project_description} = $project->description;
        $run->data->{project_metadata} = $project->metadata;
        $run->save($db);
        
        return { next_step => 'choose-locations' };
    }
    
    # Show selection form
    return {
        next_step => $self->id,
        data => $self->prepare_data($db)
    };
}

method prepare_data ($db) {
    # Get all available programs/projects
    my $projects = Registry::DAO::Project->list($db);
    
    return {
        projects => $projects
    };
}

method template { 'program-location-assignment/select-program' }

1;