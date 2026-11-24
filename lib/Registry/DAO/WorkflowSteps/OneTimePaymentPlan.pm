# ABOUTME: offer-publishing step: whether the offer may be paid for once, in full.
# ABOUTME: Each payment form is its own step; publishing refuses a version no step offered a plan for.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::OneTimePaymentPlan :isa(Registry::DAO::WorkflowStep) {

    method process ( $db, $form_data, $run = undef ) {
        my $choice = $form_data->{one_time} // '';
        return { stay => 1, errors => ['Say whether a one-time payment is offered'] }
            unless $choice eq 'offered' || $choice eq 'declined';
        return { one_time_payment => { one_time => $choice } };
    }
}

1;
