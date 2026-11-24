# ABOUTME: offer-publishing step: choose one of this tenant's resources and name the offer.
# ABOUTME: Resources are read from the run's own schema, so another tenant's are never offered or accepted.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::OfferBasics :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Offer;
    use Registry::DAO::Project;
    use Registry::DAO::Resource;

    my $UUID = qr/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i;

    method process ( $db, $form_data, $run = undef ) {
        my ( $resource_id, $name ) = $form_data->@{qw( resource_id offer_name )};
        $name = ref $name ? '' : ( $name // '' ) =~ s/\A\s+|\s+\z//gr;

        # A new version of one of this schema's published offers, keeping its
        # name; the later steps start from its current version's terms.
        my $offer_id = $form_data->{offer_id};
        my ( %basis, %prefill );
        if ( defined $offer_id && !ref $offer_id && length $offer_id ) {
            my $offer   = $offer_id =~ $UUID && Registry::DAO::Offer->find( $db, { id => $offer_id } );
            my $current = $offer && $offer->current_version($db)
                or return { stay => 1, errors => ['Choose one of your published offers'] };
            $name    = $offer->name;
            %basis   = ( offer_id => $offer->id, based_on_version_id => $current->id );
            %prefill = _terms_of( $db, $current );
        }

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
            return { %prefill, offer_basics => { class_project_id => $class_id, offer_name => $name, %basis } };
        }

        # Unqualified, so only this schema's resources are found: another
        # tenant's id names nothing here.
        my $resource = !ref $resource_id && ( $resource_id // '' ) =~ $UUID
            ? Registry::DAO::Resource->find( $db, { id => $resource_id } ) : undef;

        my @errors;
        push @errors, 'Choose one of your resources' unless $resource;
        push @errors, 'Name the offer' unless length $name;
        return { stay => 1, errors => \@errors } if @errors;

        return { %prefill, offer_basics => { resource_id => $resource->id, offer_name => $name, %basis } };
    }

    # $version's terms in the shapes the later steps record them.
    sub _terms_of ( $db, $version ) {
        my %plan     = map { $_->{kind} => $_ } $version->payment_plans($db)->@*;
        my $policies = $version->policies;
        return (
            offer_price => { map { $_ => $version->$_ } qw( price_cents currency units_per_acceptance per_booking_cap ) },
            one_time_payment => { one_time => $plan{one_time} ? 'offered' : 'declined' },
            percentage_of_sales_payment => $plan{percentage_of_sales}
                ? { percentage_of_sales => 'offered', fraction => $plan{percentage_of_sales}{fraction} }
                : { percentage_of_sales => 'declined' },
            map( { ( "${_}_policy" => $policies->{$_} ) } grep { $policies->{$_} } qw( refund change ) ),
            map( { ( "${_}_policy" => { $_ => $policies->{$_}{kind} } ) } grep { $policies->{$_} } qw( use expiry ) ),
        );
    }

    method prepare_template_data ( $db, $run, $params = {} ) {
        my $choice = $run->data->{resource_choice} // {};
        return {
            resources            => [ Registry::DAO::Resource->find( $db, {}, { -asc => 'name' } ) ],
            offers => [ grep { $_->current_version($db) } Registry::DAO::Offer->find( $db, {}, { -asc => 'name' } ) ],
            selected_resource_id => $choice->{resource_id},
            class                => $choice->{class_project_id}
                && Registry::DAO::Project->find( $db, { id => $choice->{class_project_id} } ),
        };
    }
}

1;
