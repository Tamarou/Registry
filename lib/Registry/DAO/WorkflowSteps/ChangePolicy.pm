# ABOUTME: offer-publishing step: whether and how a held booking may move, chosen explicitly.
# ABOUTME: None, or a window in hours and a fee in cents, with its targets, price difference and approval, on an offer with occurrences.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::ChangePolicy :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Offer;
    use Registry::DAO::Resource;

    # Whole and at most nine digits, so every accepted value fits an integer column.
    my $WHOLE = qr/\A[0-9]{1,9}\z/;

    method process ( $db, $form_data, $run = undef ) {
        my %f = map { $_ => ( ref $form_data->{$_} ? '' : $form_data->{$_} // '' ) }
            qw( change window_hours fee_cents targets price_difference approval );
        # In-studio changes stay as they were, whatever the form says: within
        # the offer, at its price, with no approval (the design's call).
        @f{qw( targets price_difference approval )} = qw( same_offer same_price_only none )
            if $self->workflow($db)->slug eq 'in-studio-class-setup';

        # The window's details are dropped with none: none carries nothing.
        return { change_policy => { kind => 'none' } } if $f{change} eq 'none';
        return { stay => 1, errors => ['Choose a change policy: none, or a window with a fee'] }
            unless $f{change} eq 'window';

        my @errors;
        push @errors, 'The change window must be a whole number of hours' unless $f{window_hours} =~ $WHOLE;
        push @errors, 'The change fee must be a whole number of cents' unless $f{fee_cents} =~ $WHOLE;
        return { stay => 1, errors => \@errors } if @errors;

        my $ids = $form_data->{offer_ids};
        my %policy = (
            kind         => 'window',
            window_hours => 0 + $f{window_hours},
            fee_cents    => 0 + $f{fee_cents},
            targets      => $f{targets} eq 'offer_ids'
                ? { offer_ids => [ grep { length } ref $ids eq 'ARRAY' ? @$ids : $ids // () ] }
                : $f{targets},
            # Unanswered reads as OfferVersion reads absence.
            price_difference => length $f{price_difference} ? $f{price_difference} : 'same_price_only',
            approval         => length $f{approval} ? $f{approval} : 'none',
        );
        my $why = __PACKAGE__->refusal( $db, $run ? $run->data : {}, \%policy );
        return { stay => 1, errors => [$why] } if $why;
        return { change_policy => \%policy };
    }

    # Why $policy is not one this step records for the offer the run
    # describes, or nothing. Publish asks again, since offer-basics can be
    # answered again after this step.
    sub refusal ( $class, $db, $data, $policy ) {
        my $kind = $policy->{kind} // '';
        return if $kind eq 'none' && keys %$policy == 1;
        return 'Choose a change policy: none, or a window with a fee' unless $kind eq 'window';

        my $targets = $policy->{targets};
        if ( ref $targets eq 'HASH' ) {
            my $ids     = $targets->{offer_ids};
            my %current = map { $_->id => 1 } $class->current_offers($db)->@*;
            return 'Choose the offers a change may move to from your offers'
                unless keys %$targets == 1 && ref $ids eq 'ARRAY' && @$ids
                && !grep { !( defined $_ && !ref $_ && $current{$_} ) } @$ids;
        }
        else {
            return 'A change can move to the same offer, the same program, or a list of your offers'
                unless ( $targets // '' ) =~ /\A(?:same_offer|same_program)\z/;
        }
        return 'Choose how a change to a different price is paid'
            unless ( $policy->{price_difference} // '' ) =~ /\A(?:charge_and_refund|charge_only|same_price_only)\z/;
        return "Say whether a change needs the studio's approval"
            unless ( $policy->{approval} // '' ) =~ /\A(?:required|none)\z/;

        my $basic = ref $data->{offer_basics} eq 'HASH' ? $data->{offer_basics} : {};
        return if $basic->{class_project_id};
        my $resource = $basic->{resource_id} && Registry::DAO::Resource->find( $db, { id => $basic->{resource_id} } );
        return if $resource && $resource->event_id;
        return 'A change window needs an offer bound to an occurrence or covering a class';
    }

    # This schema's offers with a current version: those a window's targets may list.
    # Unqualified, so only this schema's offers are found.
    sub current_offers ( $class, $db ) {
        return [ grep { $_->current_version($db) } Registry::DAO::Offer->find( $db, {}, { -asc => 'name' } ) ];
    }

    method prepare_template_data ( $db, $run, $params = {} ) {
        return { %{ $run->data // {} },
            target_offers => [ map { { id => $_->id, name => $_->name } } __PACKAGE__->current_offers($db)->@* ] };
    }
}

1;
