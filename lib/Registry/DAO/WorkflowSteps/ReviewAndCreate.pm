use 5.42.0;
# ABOUTME: Workflow step that reviews all program details and creates the Project record.
# ABOUTME: Shows a summary of curriculum, requirements, and schedule; creates on confirm.

use Object::Pad;

class Registry::DAO::WorkflowSteps::ReviewAndCreate :isa(Registry::DAO::WorkflowStep) {

use Registry::DAO::Project;
use Mojo::JSON qw(encode_json);

method process ($db, $form_data, $run = undef) {
    $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };

    # No confirmation -- stay on review page
    return { stay => 1 } unless $form_data->{confirm};

    my $curriculum       = $run->data->{curriculum}       || {};
    my $requirements     = $run->data->{requirements}     || {};
    my $schedule_pattern = $run->data->{schedule_pattern} || {};

    my $project = eval {
        Registry::DAO::Project->create($db, {
            name              => $curriculum->{name},
            program_type_slug => $run->data->{program_type_slug},
            notes             => $curriculum->{description} || '',
            metadata          => {
                curriculum       => $curriculum,
                requirements     => $requirements,
                schedule_pattern => $schedule_pattern,
            },
        });
    };

    unless ($project) {
        return { errors => ['Failed to create program. Please try again.'] };
    }

    return { created_project_id => $project->id };
}

method prepare_template_data ($db, $run) {
    my $curriculum       = $run->data->{curriculum}       || {};
    my $requirements     = $run->data->{requirements}     || {};
    my $schedule_pattern = $run->data->{schedule_pattern} || {};

    # Formatted display values
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
        program_type_name    => $run->data->{program_type_name} || 'Unknown',
        curriculum           => $curriculum,
        requirements         => $requirements,
        schedule_pattern     => $schedule_pattern,
        age_range            => $age_range,
        grade_range          => $grade_range,
        duration_display     => ($schedule_pattern->{duration_weeks} || 0) . ' week(s)',
        frequency_display    => ($schedule_pattern->{sessions_per_week} || 0) . ' session(s) per week',
        session_length_display => ($schedule_pattern->{session_duration_minutes} || 0) . ' minutes',
    };
}

}
