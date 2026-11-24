# ABOUTME: offer-publishing step: choose one of this tenant's resources and name the offer.
# ABOUTME: Resources are read from the run's own schema, so another tenant's are never offered or accepted.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::OfferBasics :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Resource;

    method process ( $db, $form_data, $run = undef ) {
        my $resource_id = $form_data->{resource_id};
        my $resource = Registry::DAO::Resource->find( $db, { id => $resource_id } )
            if defined $resource_id;
        return { stay => 1, errors => ['Choose one of your resources'] } unless $resource;

        return { offer_basics => { resource_id => $resource->id, offer_name => $form_data->{offer_name} } };
    }

    method prepare_template_data ( $db, $run, $params = {} ) {
        return { resources => [ Registry::DAO::Resource->find( $db, {}, { -asc => 'name' } ) ] };
    }
}

1;
