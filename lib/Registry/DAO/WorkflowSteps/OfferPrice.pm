# ABOUTME: offer-publishing step: the price, its currency, and what one acceptance buys.
# ABOUTME: Units per acceptance and a per-booking cap; whole smallest currency units only.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::OfferPrice :isa(Registry::DAO::WorkflowStep) {

    method process ( $db, $form_data, $run = undef ) {
        return { offer_price => {
            price_cents          => $form_data->{price_cents},
            currency             => lc( $form_data->{currency} // '' ),
            units_per_acceptance => $form_data->{units_per_acceptance},
            per_booking_cap      => $form_data->{per_booking_cap},
        } };
    }
}

1;
