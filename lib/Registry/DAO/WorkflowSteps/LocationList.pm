use 5.42.0;
# ABOUTME: Workflow step that lists existing locations for edit or offers
# ABOUTME: a path to create a new one in location-management.

use Object::Pad;

class Registry::DAO::WorkflowSteps::LocationList :isa(Registry::DAO::WorkflowStep) {

use Registry::DAO::Location;

method process ($db, $form_data, $run = undef) {
    $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };

    my $action = $form_data->{action} // '';

    if ($action eq 'new') {
        $run->update_data($db, {
            editing_location_id => undef,
            location_pending    => undef,
        });
        return { next_step => 'location-details' };
    }

    if ($action eq 'edit') {
        my $id = $form_data->{id} // '';
        my $loc = $id
            ? Registry::DAO::Location->find($db, { id => $id })
            : undef;

        unless ($loc) {
            return {
                stay   => 1,
                errors => ["Unknown location: $id"],
            };
        }

        $run->update_data($db, {
            editing_location_id => $id,
            location_pending    => undef,
        });
        return { next_step => 'location-details' };
    }

    return { stay => 1 };
}

method prepare_template_data ($db, $run, $params = {}) {
    return {
        locations => Registry::DAO::Location->list($db),
    };
}

}
