# ABOUTME: session-setup step: what happens when an instalment is missed: keep and owe, end, or a grace of some days.
# ABOUTME: Asked only when the run offers instalments; otherwise it is passed through and records no policy.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::MissedPaymentPolicy :isa(Registry::DAO::WorkflowStep) {

    # Nothing to ask without an instalment plan, so the controller passes this step through.
    method nothing_to_ask ( $db, $run ) { !$run->data->{instalment_payment} }

    method process ( $db, $form_data, $run = undef ) {
        return { missed_payment_policy => undef } if $run && $self->nothing_to_ask( $db, $run );

        my %f = map { $_ => ( ref $form_data->{$_} ? '' : $form_data->{$_} // '' ) } qw( missed_payment grace_days );
        return { missed_payment_policy => { kind => $f{missed_payment} } }
            if $f{missed_payment} eq 'keep_and_owe' || $f{missed_payment} eq 'end';
        return { stay => 1, errors => ['Choose what happens when an instalment is missed'] }
            unless $f{missed_payment} eq 'grace';
        # Four digits at most, so every accepted number fits an integer.
        return { stay => 1, errors => ['A grace period is a whole number of days of at least one'] }
            unless $f{grace_days} =~ /\A[1-9][0-9]{0,3}\z/;
        return { missed_payment_policy => { kind => 'grace', days => 0 + $f{grace_days} } };
    }
}

1;
