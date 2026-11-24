# ABOUTME: offer-publishing step: choose one of this tenant's resources and name the offer.
# ABOUTME: Resources are read from the run's own schema, so another tenant's are never offered or accepted.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::OfferBasics :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Project;
    use Registry::DAO::Resource;

    my $UUID = qr/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i;

    method process ( $db, $form_data, $run = undef ) {
        my ( $resource_id, $name ) = $form_data->@{qw( resource_id offer_name )};
        $name = ref $name ? '' : ( $name // '' ) =~ s/\A\s+|\s+\z//gr;

        # Class mode: the resource step wrote the class key, re-checked here
        # against this schema, and the offer covers the class's occurrences.
        my $class_id = $run && ( $run->data->{resource_choice} // {} )->{class_project_id};
        if ($class_id) {
            my @errors;
            push @errors, 'Choose one of your classes'
                unless !ref $class_id && $class_id =~ $UUID
                && Registry::DAO::Project->find( $db, { id => $class_id } );
            push @errors, 'Name the offer' unless length $name;
            return { stay => 1, errors => \@errors } if @errors;
            return { offer_basics => { class_project_id => $class_id, offer_name => $name } };
        }

        # Unqualified, so only this schema's resources are found: another
        # tenant's id names nothing here.
        my $resource = !ref $resource_id && ( $resource_id // '' ) =~ $UUID
            ? Registry::DAO::Resource->find( $db, { id => $resource_id } ) : undef;

        my @errors;
        push @errors, 'Choose one of your resources' unless $resource;
        push @errors, 'Name the offer' unless length $name;
        return { stay => 1, errors => \@errors } if @errors;

        return { offer_basics => { resource_id => $resource->id, offer_name => $name } };
    }

    method prepare_template_data ( $db, $run, $params = {} ) {
        my $choice = $run->data->{resource_choice} // {};
        return {
            resources            => [ Registry::DAO::Resource->find( $db, {}, { -asc => 'name' } ) ],
            selected_resource_id => $choice->{resource_id},
            class                => $choice->{class_project_id}
                && Registry::DAO::Project->find( $db, { id => $choice->{class_project_id} } ),
        };
    }
}

1;
