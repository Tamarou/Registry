use 5.40.2;
use experimental 'signatures', 'try', 'builtin';
use Object::Pad;

class Registry::DAO::WorkflowSteps::ReviewAndCreate :isa(Registry::DAO::WorkflowStep) {

use Registry::DAO::Project;
use Registry::DAO::Event;
use Mojo::JSON qw(encode_json);

method process ($db, $form_data) {
    my $workflow = $self->workflow($db);
    my $run = $workflow->latest_run($db);
    
    # If user wants to go back and edit
    if ($form_data->{action} && $form_data->{action} eq 'edit') {
        my $edit_step = $form_data->{edit_step} || 'curriculum-details';
        return { next_step => $edit_step };
    }
    
    # If form was submitted to create
    if ($form_data->{confirm}) {
        # Create the program (project)
        my $project = $self->create_program($db, $run);
        
        if ($project) {
            # Store project ID for completion page
            $run->data->{created_project_id} = $project->id;
            $run->save($db);
            
            return { next_step => 'complete' };
        } else {
            return {
                next_step => $self->id,
                errors => ['Failed to create program. Please try again.'],
                data => $self->prepare_data($db, $run)
            };
        }
    }
    
    # Show review page
    return {
        next_step => $self->id,
        data => $self->prepare_data($db, $run)
    };
}

method create_program ($db, $run) {
    my $curriculum = $run->data->{curriculum} || {};
    my $requirements = $run->data->{requirements} || {};
    my $schedule_pattern = $run->data->{schedule_pattern} || {};
    
    # Create a placeholder event (programs need an event in current schema)
    # In a real implementation, this might be handled differently
    my $event = Registry::DAO::Event->new(
        name => $curriculum->{name} . ' - Program Definition',
        config => {
            is_program_template => 1,
            created_via => 'program_creation_workflow',
        }
    )->save($db);
    
    # Create the project with all program details
    my $project = Registry::DAO::Project->new(
        name => $curriculum->{name},
        event_id => $event->id,
        program_type_id => $run->data->{program_type_id},
        config => encode_json({
            curriculum => $curriculum,
            requirements => $requirements,
            schedule_pattern => $schedule_pattern,
            created_by_workflow => $run->workflow_id,
            created_at => time,
        })
    )->save($db);
    
    return $project;
}

method prepare_data ($db, $run) {
    my $curriculum = $run->data->{curriculum} || {};
    my $requirements = $run->data->{requirements} || {};
    my $schedule_pattern = $run->data->{schedule_pattern} || {};
    
    # Format days of week for display
    my $days_display = '';
    if ($schedule_pattern->{days_of_week} && @{$schedule_pattern->{days_of_week}}) {
        $days_display = join(', ', @{$schedule_pattern->{days_of_week}});
    }
    
    # Format age/grade range
    my $age_range = '';
    if ($requirements->{min_age} || $requirements->{max_age}) {
        my $min = $requirements->{min_age} || 'Any';
        my $max = $requirements->{max_age} || 'Any';
        $age_range = "$min - $max years";
    }
    
    my $grade_range = '';
    if ($requirements->{min_grade} || $requirements->{max_grade}) {
        my $min = $requirements->{min_grade} || 'Any';
        my $max = $requirements->{max_grade} || 'Any';
        $grade_range = "Grades $min - $max";
    }
    
    return {
        program_type_name => $run->data->{program_type_name} || 'Unknown',
        curriculum => $curriculum,
        requirements => $requirements,
        schedule_pattern => $schedule_pattern,
        
        # Formatted display values
        days_display => $days_display,
        age_range => $age_range,
        grade_range => $grade_range,
        duration_display => $schedule_pattern->{duration_weeks} . ' week(s)',
        frequency_display => $schedule_pattern->{sessions_per_week} . ' session(s) per week',
        session_length_display => $schedule_pattern->{session_duration_minutes} . ' minutes',
    };
}

method template { 'program-creation/review-and-create' }

}