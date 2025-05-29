use 5.40.2;
use experimental 'signatures', 'try', 'builtin';
use Object::Pad;

class Registry::DAO::WorkflowSteps::CurriculumDetails :isa(Registry::DAO::WorkflowStep) {

method process ($db, $form_data) {
    my $workflow = $self->workflow($db);
    my $run = $workflow->latest_run($db);
    
    # If form was submitted
    if ($form_data->{name}) {
        # Validate required fields
        my @errors;
        push @errors, 'Program name is required' unless $form_data->{name};
        push @errors, 'Program description is required' unless $form_data->{description};
        
        if (@errors) {
            return {
                next_step => $self->id,
                errors => \@errors,
                data => $self->prepare_data($db, $run, $form_data)
            };
        }
        
        # Store curriculum details
        $run->data->{curriculum} = {
            name => $form_data->{name},
            description => $form_data->{description},
            learning_objectives => $form_data->{learning_objectives} || '',
            materials_needed => $form_data->{materials_needed} || '',
            skills_developed => $form_data->{skills_developed} || '',
        };
        $run->save($db);
        
        return { next_step => 'requirements-and-patterns' };
    }
    
    # Show form with any existing data
    return {
        next_step => $self->id,
        data => $self->prepare_data($db, $run)
    };
}

method prepare_data ($db, $run, $form_data = {}) {
    # Get program type info for context
    my $program_type_name = $run->data->{program_type_name} || 'Unknown';
    
    # Use existing data or form data
    my $curriculum = $run->data->{curriculum} || {};
    
    return {
        program_type_name => $program_type_name,
        name => $form_data->{name} || $curriculum->{name} || '',
        description => $form_data->{description} || $curriculum->{description} || '',
        learning_objectives => $form_data->{learning_objectives} || $curriculum->{learning_objectives} || '',
        materials_needed => $form_data->{materials_needed} || $curriculum->{materials_needed} || '',
        skills_developed => $form_data->{skills_developed} || $curriculum->{skills_developed} || '',
    };
}

method template { 'program-creation/curriculum-details' }

}