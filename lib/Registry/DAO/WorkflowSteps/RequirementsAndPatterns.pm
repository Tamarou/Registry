use 5.42.0;
# ABOUTME: Workflow step for setting age/grade requirements and schedule patterns.
# ABOUTME: Validates age ranges and stores requirements + schedule config in run data.

use Object::Pad;

class Registry::DAO::WorkflowSteps::RequirementsAndPatterns :isa(Registry::DAO::WorkflowStep) {

method process ($db, $form_data, $run = undef) {
    $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };

    # No form submission -- stay on this step to show the form
    return { stay => 1 } unless exists $form_data->{min_age};

    my @errors;
    my $min_age = length($form_data->{min_age} // '') ? $form_data->{min_age} + 0 : undef;
    my $max_age = length($form_data->{max_age} // '') ? $form_data->{max_age} + 0 : undef;

    if (defined $min_age && defined $max_age && $min_age > $max_age) {
        push @errors, 'Minimum age cannot be greater than maximum age';
    }

    return { errors => \@errors } if @errors;

    return {
        requirements => {
            min_age              => $min_age,
            max_age              => $max_age,
            min_grade            => $form_data->{min_grade}            || undef,
            max_grade            => $form_data->{max_grade}            || undef,
            staff_ratio          => $form_data->{staff_ratio}          || '1:10',
            staff_qualifications => $form_data->{staff_qualifications} || '',
            equipment_needed     => $form_data->{equipment_needed}     || '',
        },
        schedule_pattern => {
            type                     => $form_data->{pattern_type}             || 'weekly',
            duration_weeks           => $form_data->{duration_weeks}           || 1,
            sessions_per_week        => $form_data->{sessions_per_week}        || 1,
            session_duration_minutes => $form_data->{session_duration_minutes} || 60,
            default_start_time       => $form_data->{default_start_time}       || '15:00',
        },
    };
}

method prepare_template_data ($db, $run, $params = {}) {
    my $requirements    = $run->data->{requirements}       || {};
    my $schedule        = $run->data->{schedule_pattern}   || {};
    my $type_config     = $run->data->{program_type_config} || {};
    my $defaults        = $type_config->{default_requirements} || {};

    return {
        program_type_name        => $run->data->{program_type_name} || 'Unknown',
        curriculum_name          => ($run->data->{curriculum} || {})->{name} || 'Untitled',
        min_age                  => $requirements->{min_age}   // $defaults->{min_age},
        max_age                  => $requirements->{max_age}   // $defaults->{max_age},
        min_grade                => $requirements->{min_grade} // $defaults->{min_grade},
        max_grade                => $requirements->{max_grade} // $defaults->{max_grade},
        staff_ratio              => $requirements->{staff_ratio}          || '1:10',
        staff_qualifications     => $requirements->{staff_qualifications} || '',
        equipment_needed         => $requirements->{equipment_needed}     || '',
        pattern_type             => $schedule->{type}                     || 'weekly',
        duration_weeks           => $schedule->{duration_weeks}           || 1,
        sessions_per_week        => $schedule->{sessions_per_week}        || 1,
        session_duration_minutes => $schedule->{session_duration_minutes} || 60,
        default_start_time       => $schedule->{default_start_time}       || '15:00',
    };
}

}
