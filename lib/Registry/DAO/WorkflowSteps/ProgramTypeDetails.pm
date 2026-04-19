use 5.42.0;
# ABOUTME: Workflow step that collects program-type details and either
# ABOUTME: creates a new ProgramType or updates the one named by editing_slug.

use Object::Pad;

class Registry::DAO::WorkflowSteps::ProgramTypeDetails :isa(Registry::DAO::WorkflowStep) {

use Registry::DAO::ProgramType;

method process ($db, $form_data, $run = undef) {
    $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };

    # No form submission yet -- stay on the page to show the form.
    return { stay => 1 } unless exists $form_data->{name};

    my @errors;
    push @errors, 'Program type name is required'
        unless defined $form_data->{name} && length $form_data->{name};

    # session_pattern is an enum -- don't trust whatever the form POSTs.
    my %valid_pattern = map { $_ => 1 } qw(weekly daily one_time);
    if (defined $form_data->{session_pattern}
        && length $form_data->{session_pattern}
        && !$valid_pattern{$form_data->{session_pattern}}) {
        push @errors, 'Invalid session pattern';
    }

    # default_capacity must be a positive integer if supplied.
    if (defined $form_data->{default_capacity} && length $form_data->{default_capacity}) {
        unless ($form_data->{default_capacity} =~ /\A\d+\z/
                && $form_data->{default_capacity} + 0 >= 1) {
            push @errors, 'Default capacity must be a positive integer';
        }
    }

    return { errors => \@errors } if @errors;

    my %config;
    $config{description}     = $form_data->{description}     if defined $form_data->{description};
    $config{session_pattern} = $form_data->{session_pattern}
        if defined $form_data->{session_pattern} && length $form_data->{session_pattern};
    $config{default_capacity} = $form_data->{default_capacity} + 0
        if defined $form_data->{default_capacity} && length $form_data->{default_capacity};

    my $editing_slug = $run->data->{editing_slug};

    if ($editing_slug) {
        my $existing = Registry::DAO::ProgramType->find_by_slug($db, $editing_slug);
        return { errors => ["Program type not found: $editing_slug"] }
            unless $existing;

        my %update_data = (
            name   => $form_data->{name},
            config => { %{ $existing->config // {} }, %config },
        );
        $existing->update($db, \%update_data);

        return { next_step => 'complete' };
    }

    # New program type
    my $created = eval {
        Registry::DAO::ProgramType->create($db, {
            name   => $form_data->{name},
            config => \%config,
        });
    };
    if (my $e = $@) {
        return { errors => ["Failed to create program type: $e"] };
    }

    return {
        next_step          => 'complete',
        created_type_slug  => $created->slug,
    };
}

method prepare_template_data ($db, $run, $params = {}) {
    my $editing_slug = $run->data->{editing_slug};
    if ($editing_slug) {
        my $existing = Registry::DAO::ProgramType->find_by_slug($db, $editing_slug);
        if ($existing) {
            my $cfg = $existing->config // {};
            return {
                editing          => 1,
                editing_slug     => $editing_slug,
                name             => $existing->name,
                description      => $cfg->{description}      // '',
                session_pattern  => $cfg->{session_pattern}  // '',
                default_capacity => $cfg->{default_capacity} // '',
            };
        }
    }

    return {
        editing          => 0,
        name             => '',
        description      => '',
        session_pattern  => '',
        default_capacity => '',
    };
}

}
