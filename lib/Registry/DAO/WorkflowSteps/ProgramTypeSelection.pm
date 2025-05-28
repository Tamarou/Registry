use 5.40.2;
use experimental 'signatures', 'try', 'builtin';
use Object::Pad;

class Registry::DAO::WorkflowSteps::ProgramTypeSelection :isa(Registry::DAO::WorkflowStep) {

use Registry::DAO::ProgramType;

method process ($db, $form_data) {
    my $workflow = $self->workflow($db);
    my $run = $workflow->latest_run($db);
    
    # If form was submitted
    if ($form_data->{program_type_id}) {
        # Validate program type exists
        my $program_type = Registry::DAO::ProgramType->new(
            id => $form_data->{program_type_id}
        )->load($db);
        
        unless ($program_type) {
            return {
                next_step => $self->id,
                errors => ['Invalid program type selected'],
                data => $self->prepare_data($db)
            };
        }
        
        # Store selection in workflow data
        $run->data->{program_type_id} = $program_type->id;
        $run->data->{program_type_name} = $program_type->name;
        $run->data->{program_type_config} = $program_type->config;
        $run->save($db);
        
        return { next_step => 'curriculum-details' };
    }
    
    # Show selection form
    return {
        next_step => $self->id,
        data => $self->prepare_data($db)
    };
}

method prepare_data ($db) {
    # Get all available program types
    my $program_types = Registry::DAO::ProgramType->list($db);
    
    return {
        program_types => $program_types
    };
}

method template { 'program-creation/program-type-selection' }

}