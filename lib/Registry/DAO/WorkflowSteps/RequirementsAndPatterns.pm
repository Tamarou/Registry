package Registry::DAO::WorkflowSteps::RequirementsAndPatterns;
use 5.40.2;
use warnings;
use experimental 'signatures', 'try', 'builtin';

use Object::Pad;
class Registry::DAO::WorkflowSteps::RequirementsAndPatterns :isa(Registry::DAO::WorkflowStep);

use Mojo::JSON qw(encode_json decode_json);

method process ($db, $form_data) {
    my $workflow = $self->workflow($db);
    my $run = $workflow->latest_run($db);
    
    # If form was submitted
    if (exists $form_data->{min_age}) {
        # Validate age requirements
        my @errors;
        my $min_age = $form_data->{min_age} || 0;
        my $max_age = $form_data->{max_age} || 99;
        
        if ($min_age && $max_age && $min_age > $max_age) {
            push @errors, 'Minimum age cannot be greater than maximum age';
        }
        
        if (@errors) {
            return {
                next_step => $self->id,
                errors => \@errors,
                data => $self->prepare_data($db, $run, $form_data)
            };
        }
        
        # Parse schedule pattern
        my $schedule_pattern = $self->parse_schedule_pattern($form_data);
        
        # Store requirements and patterns
        $run->data->{requirements} = {
            min_age => $min_age || undef,
            max_age => $max_age || undef,
            min_grade => $form_data->{min_grade} || undef,
            max_grade => $form_data->{max_grade} || undef,
            staff_ratio => $form_data->{staff_ratio} || '1:10',
            staff_qualifications => $form_data->{staff_qualifications} || '',
            equipment_needed => $form_data->{equipment_needed} || '',
        };
        
        $run->data->{schedule_pattern} = $schedule_pattern;
        $run->save($db);
        
        return { next_step => 'review-and-create' };
    }
    
    # Show form
    return {
        next_step => $self->id,
        data => $self->prepare_data($db, $run)
    };
}

method parse_schedule_pattern ($form_data) {
    my $pattern = {
        type => $form_data->{pattern_type} || 'weekly',
        duration_weeks => $form_data->{duration_weeks} || 1,
        sessions_per_week => $form_data->{sessions_per_week} || 1,
        session_duration_minutes => $form_data->{session_duration_minutes} || 60,
    };
    
    # Parse days of week if weekly pattern
    if ($pattern->{type} eq 'weekly' && $form_data->{days_of_week}) {
        my @days = ref $form_data->{days_of_week} eq 'ARRAY' 
            ? @{$form_data->{days_of_week}}
            : ($form_data->{days_of_week});
        $pattern->{days_of_week} = \@days;
    }
    
    # Parse default times
    if ($form_data->{default_start_time}) {
        $pattern->{default_start_time} = $form_data->{default_start_time};
    }
    
    return $pattern;
}

method prepare_data ($db, $run, $form_data = {}) {
    my $program_type_config = $run->data->{program_type_config} || {};
    my $requirements = $run->data->{requirements} || {};
    my $schedule_pattern = $run->data->{schedule_pattern} || {};
    
    # Get defaults from program type config
    my $defaults = $program_type_config->{default_requirements} || {};
    
    return {
        program_type_name => $run->data->{program_type_name} || 'Unknown',
        curriculum_name => $run->data->{curriculum}->{name} || 'Untitled',
        
        # Age/grade requirements
        min_age => $form_data->{min_age} // $requirements->{min_age} // $defaults->{min_age},
        max_age => $form_data->{max_age} // $requirements->{max_age} // $defaults->{max_age},
        min_grade => $form_data->{min_grade} // $requirements->{min_grade} // $defaults->{min_grade},
        max_grade => $form_data->{max_grade} // $requirements->{max_grade} // $defaults->{max_grade},
        
        # Staff requirements
        staff_ratio => $form_data->{staff_ratio} || $requirements->{staff_ratio} || '1:10',
        staff_qualifications => $form_data->{staff_qualifications} || $requirements->{staff_qualifications} || '',
        equipment_needed => $form_data->{equipment_needed} || $requirements->{equipment_needed} || '',
        
        # Schedule pattern
        pattern_type => $form_data->{pattern_type} || $schedule_pattern->{type} || 'weekly',
        duration_weeks => $form_data->{duration_weeks} || $schedule_pattern->{duration_weeks} || 1,
        sessions_per_week => $form_data->{sessions_per_week} || $schedule_pattern->{sessions_per_week} || 1,
        session_duration_minutes => $form_data->{session_duration_minutes} || $schedule_pattern->{session_duration_minutes} || 60,
        days_of_week => $form_data->{days_of_week} || $schedule_pattern->{days_of_week} || [],
        default_start_time => $form_data->{default_start_time} || $schedule_pattern->{default_start_time} || '15:00',
        
        # Program type defaults for reference
        program_type_defaults => $program_type_config->{standard_times} || {},
    };
}

method template { 'program-creation/requirements-and-patterns' }

1;