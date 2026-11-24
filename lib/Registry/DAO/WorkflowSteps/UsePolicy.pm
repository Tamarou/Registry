# ABOUTME: offer-publishing step: what counts as using the offer's entitlement, chosen explicitly.
# ABOUTME: Day one offers optional attendance or none; make-ups are a later shape and are refused here.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::UsePolicy :isa(Registry::DAO::WorkflowStep) {

    # The use policies this step offers, a subset of OfferVersion's declared
    # kinds: a kind added there is not offered until it is added here too.
    my %OFFERED = map { $_ => 1 } qw( optional_attendance none );

    method process ( $db, $form_data, $run = undef ) {
        my $choice = $form_data->{use};
        return { stay => 1, errors => ['Choose a use policy: optional attendance or none'] }
            unless defined $choice && !ref $choice && $OFFERED{$choice};
        return { use_policy => { use => $choice } };
    }
}

1;
