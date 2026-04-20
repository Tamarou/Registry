use 5.42.0;
# ABOUTME: Orchestrator step for the program-setup workflow. Renders a
# ABOUTME: checklist of setup pieces and offers a callcc button for each.

use Object::Pad;

class Registry::DAO::WorkflowSteps::ProgramSetupOverview :isa(Registry::DAO::WorkflowStep) {

method process ($db, $form_data, $run = undef) {
    # Overview is read-only; all transitions happen via callcc links
    # rendered in the template.
    return { stay => 1 };
}

method prepare_template_data ($db, $run, $params = {}) {
    my $raw = $db isa Registry::DAO ? $db->db : $db;

    my $program_type_count = $raw->query(
        'SELECT COUNT(*) FROM program_types'
    )->array->[0];

    my $location_count = $raw->query(
        'SELECT COUNT(*) FROM locations'
    )->array->[0];

    my $project_count = $raw->query(
        'SELECT COUNT(*) FROM projects'
    )->array->[0];

    my $session_count = $raw->query(
        'SELECT COUNT(*) FROM sessions'
    )->array->[0];

    my $pricing_count = $raw->query(
        'SELECT COUNT(*) FROM pricing_plans'
    )->array->[0];

    my @checklist = (
        {
            key            => 'program_types',
            label          => 'Program Types',
            description    => 'Define the kinds of programs you offer (e.g. after-school, summer camp).',
            callcc_target  => 'program-type-management',
            count          => $program_type_count,
            status         => $program_type_count > 0 ? 'done' : 'todo',
        },
        {
            key            => 'locations',
            label          => 'Locations',
            description    => 'Add the schools and studios where programs are held.',
            callcc_target  => 'location-management',
            count          => $location_count,
            status         => $location_count > 0 ? 'done' : 'todo',
        },
        {
            key            => 'programs',
            label          => 'Programs',
            description    => 'Create the programs parents will register for.',
            callcc_target  => 'program-creation',
            count          => $project_count,
            status         => $project_count > 0 ? 'done' : 'todo',
        },
        {
            key            => 'sessions',
            label          => 'Sessions & Events',
            description    => 'Assign programs to locations and generate the session schedule.',
            callcc_target  => 'program-location-assignment',
            count          => $session_count,
            status         => $session_count > 0 ? 'done' : 'todo',
        },
        {
            key            => 'pricing',
            label          => 'Pricing',
            description    => 'Set up pricing plans for your sessions.',
            callcc_target  => 'pricing-plan-creation',
            count          => $pricing_count,
            status         => $pricing_count > 0 ? 'done' : 'todo',
        },
    );

    my $done  = scalar grep { $_->{status} eq 'done' } @checklist;
    my $total = scalar @checklist;

    return {
        checklist      => \@checklist,
        total_done     => $done,
        total_items    => $total,
        ready_to_publish => $done == $total,
    };
}

}
