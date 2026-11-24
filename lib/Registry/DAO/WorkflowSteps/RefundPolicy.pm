# ABOUTME: offer-publishing step: whether money comes back on a refund, chosen explicitly with no default.
# ABOUTME: None; full until a cutoff in hours, on an occurrence or class offer; or keep the fee, on a percentage offer.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::RefundPolicy :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Resource;

    # The refund policies this step offers, OfferVersion's day-one kinds; a
    # cutoff is offered in hours only (cutoff_at is not offered here).
    my %OFFERED = map { $_ => 1 } qw( none full_until_cutoff keep_fee_with_admin_exception );

    # Why $policy does not fit the offer the run $data describes, or undef.
    # Publish asks again, so an earlier step answered differently since
    # cannot carry a policy past it.
    sub refusal ( $class, $db, $data, $policy ) {
        my $kind = $policy->{kind};
        if ( $kind eq 'full_until_cutoff' ) {
            my $basic = ref $data->{offer_basics} eq 'HASH' ? $data->{offer_basics} : {};
            my $resource = $basic->{resource_id}
                && Registry::DAO::Resource->find( $db, { id => $basic->{resource_id} } );
            return 'A refund cutoff needs an offer bound to one occurrence or covering a class'
                unless $basic->{class_project_id} || ( $resource && $resource->event_id );
        }
        if ( $kind eq 'keep_fee_with_admin_exception' ) {
            # It names the platform's application fee, which only a
            # percentage-of-sales plan gives the offer a say over.
            return 'Keeping the fee needs an offer with a percentage-of-sales payment plan'
                unless ( ( $data->{percentage_of_sales_payment} // {} )->{percentage_of_sales} // '' ) eq 'offered';
        }
        return;
    }

    method process ( $db, $form_data, $run = undef ) {
        my $kind = $form_data->{refund};
        return { stay => 1, errors => ['Choose a refund policy: none, full until a cutoff, or keep the fee'] }
            unless defined $kind && !ref $kind && $OFFERED{$kind};

        my %policy = ( kind => $kind );
        if ( $kind eq 'full_until_cutoff' ) {
            my $hours = $form_data->{cutoff_hours};
            return { stay => 1, errors => ['The cutoff must be a whole number of hours before the start, such as 24'] }
                unless defined $hours && !ref $hours && $hours =~ /\A[0-9]{1,6}\z/;
            $policy{cutoff_hours} = 0 + $hours;
        }

        my $why = $self->refusal( $db, $run ? $run->data : {}, \%policy );
        return { stay => 1, errors => [$why] } if $why;
        return { refund_policy => \%policy };
    }
}

1;
