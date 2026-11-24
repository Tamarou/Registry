# ABOUTME: offer-publishing step: whether and how a held booking may move, chosen explicitly.
# ABOUTME: Day one offers none, or a window in hours, a fee in cents and same-offer targets on an offer with occurrences.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::ChangePolicy :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Resource;

    # Whole and at most nine digits, so every accepted value fits an integer column.
    my $WHOLE = qr/\A[0-9]{1,9}\z/;

    method process ( $db, $form_data, $run = undef ) {
        my %f = map { $_ => ( ref $form_data->{$_} ? '' : $form_data->{$_} // '' ) }
            qw( change window_hours fee_cents targets );

        # The window's details are dropped with none: none carries nothing.
        return { change_policy => { kind => 'none' } } if $f{change} eq 'none';
        return { stay => 1, errors => ['Choose a change policy: none, or a window with a fee'] }
            unless $f{change} eq 'window';

        my @errors;
        push @errors, 'The change window must be a whole number of hours' unless $f{window_hours} =~ $WHOLE;
        push @errors, 'The change fee must be a whole number of cents' unless $f{fee_cents} =~ $WHOLE;
        # The day-one rule: only another occurrence of this same offer.
        push @errors, 'A change can only move to another occurrence of the same offer'
            unless $f{targets} eq 'same_offer';
        push @errors, 'A change window needs an offer bound to an occurrence or covering a class'
            unless $self->_has_occurrences( $db, $run );
        return { stay => 1, errors => \@errors } if @errors;

        return { change_policy => {
            kind         => 'window',
            window_hours => 0 + $f{window_hours},
            fee_cents    => 0 + $f{fee_cents},
            targets      => 'same_offer',
        } };
    }

    # What offer-basics recorded: a class, or a resource that is an occurrence.
    method _has_occurrences ( $db, $run ) {
        my $basic = $run && ref $run->data->{offer_basics} eq 'HASH' ? $run->data->{offer_basics} : {};
        return 1 if $basic->{class_project_id};
        my $resource = $basic->{resource_id} && Registry::DAO::Resource->find( $db, { id => $basic->{resource_id} } );
        return $resource && $resource->event_id;
    }
}

1;
