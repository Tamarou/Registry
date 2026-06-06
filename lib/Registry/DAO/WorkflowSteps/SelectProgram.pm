use 5.42.0;

use Object::Pad;

class Registry::DAO::WorkflowSteps::SelectProgram :isa(Registry::DAO::WorkflowStep) {

use Registry::DAO::Project;
use Registry::DAO::ProgramType;

method process ($db, $form_data, $run = undef) {
    $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };
    
    # If form was submitted
    if ($form_data->{project_id}) {
        # Validate project exists
        my $project = Registry::DAO::Project->find($db, {
            id => $form_data->{project_id}
        });

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

        # Capture the program type config (e.g. standard_times) so the
        # configure-location and generate-events steps can default the per-
        # location schedule. The project metadata does not carry this.
        if ($project->program_type_slug) {
            my $program_type = Registry::DAO::ProgramType->find_by_slug(
                $db, $project->program_type_slug
            );
            $run->data->{program_type_config} = $program_type->config
                if $program_type;
        }
        $run->save($db);
        
        return { next_step => 'choose-locations' };
    }
    
    # Show selection form
    return {
        next_step => $self->id,
        data => $self->prepare_data($db)
    };
}

# Render contract: templates read stash('step_data'), so wrap prepare_data
# under that key for the controller's GET render path.
method prepare_template_data ($db, $run, $params = {}) {
    return { step_data => $self->prepare_data($db) };
}

method prepare_data ($db) {
    # Get all available programs/projects
    my $projects = Registry::DAO::Project->list($db);

    return {
        projects => $projects
    };
}

method template { 'program-location-assignment/select-program' }

}