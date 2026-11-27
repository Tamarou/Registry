# ABOUTME: offer-publishing step: what counts as using the offer's entitlement, chosen explicitly.
# ABOUTME: Optional attendance, none, or make-ups: a missed day earns a credit to one of this tenant's current class offers.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::UsePolicy :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Offer;

    my $UUID = qr/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i;
    # A whole number from 1 to 3650, as OfferVersion accepts.
    my $DAYS = sub ($v) { defined $v && !ref $v && $v =~ /\A[1-9][0-9]{0,3}\z/ && $v <= 3650 };

    # This schema's offers whose current version covers a class: the make-up choices.
    # Unqualified, so only this schema's offers are found.
    sub class_offers ( $class, $db ) {
        return [ grep { my $v = $_->current_version($db); $v && $v->class_project_id }
            Registry::DAO::Offer->find( $db, {}, { -asc => 'name' } ) ];
    }

    # Why $policy is not one this step records, or nothing. Publish asks it
    # of the run's data too, since the make-up offer can change after this step.
    sub refusal ( $class, $db, $data, $policy ) {
        my $use = ref $policy eq 'HASH' ? $policy->{use} // '' : '';
        return if ( $use eq 'optional_attendance' || $use eq 'none' ) && keys %$policy == 1;
        return 'Choose a use policy: optional attendance, none, or make-ups' unless $use eq 'makeup';

        my $id = $policy->{offer_id};
        return 'Choose one of your current class offers for make-ups'
            unless defined $id && !ref $id && $id =~ $UUID && grep { $_->id eq $id } $class->class_offers($db)->@*;
        return 'A make-up credit lasts a whole number of days from 1 to 3650' unless $DAYS->( $policy->{credit_days} );
        return 'Make-ups per term are a whole number from 1 to 3650, or left blank'
            if exists $policy->{max_per_term} && !$DAYS->( $policy->{max_per_term} );
        return 'Choose a use policy: optional attendance, none, or make-ups'
            if grep { !/\A(?:use|offer_id|credit_days|max_per_term)\z/ } keys %$policy;
        return;
    }

    method process ( $db, $form_data, $run = undef ) {
        my %f = map { $_ => ( ref $form_data->{$_} ? '' : $form_data->{$_} // '' ) }
            qw( use makeup_offer_id credit_days max_per_term );
        my %policy = ( use => $f{use} );
        if ( $f{use} eq 'makeup' ) {
            @policy{qw( offer_id credit_days )} = @f{qw( makeup_offer_id credit_days )};
            $policy{max_per_term} = $f{max_per_term} if length $f{max_per_term};
        }
        my $why = __PACKAGE__->refusal( $db, $run ? $run->data : {}, \%policy );
        return { stay => 1, errors => [$why] } if $why;
        $policy{$_} += 0 for grep { exists $policy{$_} } qw( credit_days max_per_term );    # stored as numbers
        return { use_policy => \%policy };
    }

    method prepare_template_data ( $db, $run, $params = {} ) {
        return { %{ $run->data // {} },
            makeup_offers => [ map { { id => $_->id, name => $_->name } } __PACKAGE__->class_offers($db)->@* ] };
    }
}

1;
