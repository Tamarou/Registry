use 5.42.0;
# ABOUTME: Workflow step that lists existing program types for edit or
# ABOUTME: offers a path to create a new one in program-type-management.

use Object::Pad;

class Registry::DAO::WorkflowSteps::ProgramTypeList :isa(Registry::DAO::WorkflowStep) {

use Registry::DAO::ProgramType;

method process ($db, $form_data, $run = undef) {
    $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };

    my $action = $form_data->{action} // '';

    if ($action eq 'new') {
        # Clear any carried editing_slug and advance.
        $run->update_data($db, { editing_slug => undef });
        return { next_step => 'type-details' };
    }

    if ($action eq 'edit') {
        my $slug = $form_data->{slug} // '';
        my $type = $slug
            ? Registry::DAO::ProgramType->find_by_slug($db, $slug)
            : undef;

        unless ($type) {
            return {
                stay   => 1,
                errors => ["Unknown program type: $slug"],
            };
        }

        # Carry the editing slug forward via run data and advance.
        $run->update_data($db, { editing_slug => $slug });
        return {
            next_step    => 'type-details',
            editing_slug => $slug,
        };
    }

    # No action submitted -- stay on the list view.
    return { stay => 1 };
}

method prepare_template_data ($db, $run, $params = {}) {
    return {
        program_types => Registry::DAO::ProgramType->list($db),
    };
}

}
