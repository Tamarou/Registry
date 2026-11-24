# ABOUTME: offer-publishing step: review the terms the run collected and publish them as an offer version.
# ABOUTME: The version belongs to the tenant whose schema the run is in; once published the database keeps it immutable.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::PublishOfferVersion :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Offer;

    method process ( $db, $form_data, $run = undef ) {
        return { stay => 1 } unless ( $form_data->{action} // '' ) eq 'publish';

        my $data  = $run->data;
        my $basic = $data->{offer_basics} // {};
        my $price = $data->{offer_price}  // {};

        my $tx      = $db->begin;
        my $offer   = Registry::DAO::Offer->create( $db, { name => $basic->{offer_name} } );
        my $version = $offer->draft( $db, {
            resource_id => $basic->{resource_id},
            $price->%{qw( price_cents currency units_per_acceptance per_booking_cap )},
            payment_plans => [
                ( $data->{one_time_payment} // {} )->{one_time} eq 'offered'
                    ? { id => 'one_time', kind => 'one_time' } : ()
            ],
            policies => { refund => { kind => $form_data->{refund} } },
        } )->publish($db);
        $tx->commit;

        return { published_offer_version_id => $version->id };
    }

    method prepare_template_data ( $db, $run, $params = {} ) {
        return $run->data;
    }
}

1;
