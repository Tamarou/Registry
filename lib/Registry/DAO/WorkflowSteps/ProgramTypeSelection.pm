use 5.42.0;
# ABOUTME: Workflow step for selecting a program type when creating a new program.
# ABOUTME: Loads available program types and stores the selection in workflow run data.

use Object::Pad;

class Registry::DAO::WorkflowSteps::ProgramTypeSelection :isa(Registry::DAO::WorkflowStep) {

use Registry::DAO::ProgramType;

method process ($db, $form_data, $run = undef) {
    $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };

    if ($form_data->{program_type_slug}) {
        my $program_type = Registry::DAO::ProgramType->find($db, {
            slug => $form_data->{program_type_slug},
        });

        unless ($program_type) {
            return { errors => ['Invalid program type selected'] };
        }

        return {
            program_type_slug   => $program_type->slug,
            program_type_name   => $program_type->name,
            program_type_config => $program_type->config,
        };
    }

    # No selection submitted -- stay on this step to show the form
    return { stay => 1 };
}

method prepare_template_data ($db, $run) {
    my $program_types = Registry::DAO::ProgramType->list($db);
    return {
        program_types => $program_types,
    };
}

}
