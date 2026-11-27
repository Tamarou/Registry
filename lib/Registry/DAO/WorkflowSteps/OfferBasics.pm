# ABOUTME: offer-publishing step: choose one of this tenant's resources, or a session run's sessions, and name the offer.
# ABOUTME: Resources are read from the run's own schema, so another tenant's are never offered or accepted.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::OfferBasics :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Offer;
    use Registry::DAO::Project;
    use Registry::DAO::Resource;
    use List::Util qw( uniq );

    my $UUID = qr/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i;

    # Every run key _terms_of may copy.
    my @TERMS = qw( offer_price one_time_payment percentage_of_sales_payment
        refund_policy change_policy use_policy expiry_policy instalment_payment missed_payment_policy );

    # Why $ids are not sessions of the session run $data's program, or nothing.
    # Publish asks again, so a run whose sessions changed since cannot publish.
    sub session_refusal ( $class, $db, $data, $ids ) {
        my $program = ( ref $data->{session_program} eq 'HASH' ? $data->{session_program} : {} )->{project_id};
        my %ours = map { $_->id => 1 } $program ? Registry::DAO::Resource->sessions_of( $db, $program )->@* : ();
        return q{Choose at least one of the program's sessions}
            unless ref $ids eq 'ARRAY' && @$ids && !grep { !( defined && !ref && $ours{$_} ) } @$ids;
        return;
    }

    # Whether the offer the run $data describes has days: a class's
    # occurrences, or every resource it names an occurrence or a session.
    sub bound ( $class, $db, $data ) {
        my $basic = ref $data->{offer_basics} eq 'HASH' ? $data->{offer_basics} : {};
        return 1 if $basic->{class_project_id};
        return Registry::DAO::Resource->all_have_days( $db, grep { defined && !ref } $basic->{resource_id},
            ref $basic->{resource_ids} eq 'ARRAY' ? $basic->{resource_ids}->@* : () );
    }

    method process ( $db, $form_data, $run = undef ) {
        my ( $resource_id, $name ) = $form_data->@{qw( resource_id offer_name )};
        $name = ref $name ? '' : ( $name // '' ) =~ s/\A\s+|\s+\z//gr;

        # Session mode: a new offer over some of the program's sessions.
        if ( $run && $run->data->{session_program} ) {
            my $ids = $form_data->{resource_ids};
            my @ids = uniq grep { defined && length } ref $ids eq 'ARRAY' ? @$ids : $ids // ();
            my @errors = grep { defined } __PACKAGE__->session_refusal( $db, $run->data, \@ids );
            push @errors, 'Name the offer' unless length $name;
            return { stay => 1, errors => \@errors } if @errors;
            return { offer_basics => { resource_ids => \@ids, offer_name => $name } };
        }

        # A new version of one of this schema's published offers, keeping its
        # name; the later steps start from its current version's terms.
        # The run's data only merges, so copied terms are cleared with nulls: all
        # of them before copying an offer's, and after one when a new offer is chosen.
        my %cleared  = map { $_ => undef } @TERMS;
        my $offer_id = $form_data->{offer_id};
        my %basis;
        my %prefill = $run && ( $run->data->{offer_basics} // {} )->{based_on_version_id} ? %cleared : ();
        my $class_id = $run && ( $run->data->{resource_choice} // {} )->{class_project_id};
        if ( defined $offer_id && !ref $offer_id && length $offer_id ) {
            my $offer   = $offer_id =~ $UUID && Registry::DAO::Offer->find( $db, { id => $offer_id } );
            my $current = $offer && $offer->current_version($db)
                or return { stay => 1, errors => ['Choose one of your published offers'] };
            # Its new version sells what the current one does, never this
            # run's other class or resource: that would take the offer from its own.
            return { stay => 1, errors => [ $class_id
                ? 'Choose one of the offers for this class' : 'Choose one of the offers for this resource' ] }
                unless _sells( $current, $class_id, $resource_id );
            $name    = $offer->name;
            %basis   = ( offer_id => $offer->id, based_on_version_id => $current->id );
            %prefill = ( %cleared, _terms_of( $db, $current ) );
        }

        # Class mode: the resource step wrote the class key, re-checked here
        # against this schema, and the offer covers the class's occurrences.
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

    # Does $version sell class $class_id, or else resource $resource_id?
    sub _sells ( $version, $class_id, $resource_id ) {
        my $sells = $class_id ? $version->class_project_id : $version->resource_id;
        my $want  = $class_id // $resource_id;
        return defined $sells && defined $want && !ref $want && $sells eq $want;
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
            instalment_payment => $plan{instalments} && { $plan{instalments}->%{qw( id count cadence surcharge_pct )} },
            missed_payment_policy => $policies->{missed_payment},
            map( { ( "${_}_policy" => $policies->{$_} ) } grep { $policies->{$_} } qw( refund change ) ),
            # use and expiry are stored under their own name, not kind; a make-up keeps its fields.
            map( { my %p = $policies->{$_}->%*; ( "${_}_policy" => { $_ => delete $p{kind}, %p } ) }
                grep { $policies->{$_} } qw( use expiry ) ),
        );
    }

    method prepare_template_data ( $db, $run, $params = {} ) {
        if ( my $program = $run->data->{session_program} ) {
            return { sessions => Registry::DAO::Resource->sessions_of( $db, $program->{project_id} ),
                chosen => { map { $_ => 1 } ( ( $run->data->{offer_basics} // {} )->{resource_ids} // [] )->@* } };
        }
        my $choice = $run->data->{resource_choice} // {};
        return {
            resources            => [ Registry::DAO::Resource->find( $db, {}, { -asc => 'name' } ) ],
            # Only offers a new version of which this run may publish: the
            # class's, or one selling a single resource (the chosen one, once known).
            offers => [ grep {
                my $current = $_->current_version($db);
                $current && ( $choice->{class_project_id} || $choice->{resource_id}
                    ? _sells( $current, $choice->@{qw( class_project_id resource_id )} )
                    : defined $current->resource_id )
            } Registry::DAO::Offer->find( $db, {}, { -asc => 'name' } ) ],
            selected_resource_id => $choice->{resource_id},
            class                => $choice->{class_project_id}
                && Registry::DAO::Project->find( $db, { id => $choice->{class_project_id} } ),
        };
    }
}

1;
