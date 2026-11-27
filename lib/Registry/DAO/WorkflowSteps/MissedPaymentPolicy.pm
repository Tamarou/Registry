# ABOUTME: session-setup step: what happens when an instalment is missed: keep and owe, end, or a grace of some days.
# ABOUTME: Asked only when the run offers instalments; otherwise it is passed through and records no policy.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::MissedPaymentPolicy :isa(Registry::DAO::WorkflowStep) {

    # Why $policy is not one this step records, or nothing. Publish asks it
    # of the run's data too, which nothing but this step should have written.
    sub refusal ( $class, $db, $data, $policy ) {
        my $kind = ref $policy eq 'HASH' ? $policy->{kind} // '' : '';
        if ( $kind eq 'grace' ) {
            return 'A grace period is a whole number of days from 1 to 9999'
                unless keys %$policy == 2 && ( $policy->{days} // '' ) =~ /\A[1-9][0-9]{0,3}\z/;
            return;
        }
        return if ( $kind eq 'keep_and_owe' || $kind eq 'end' ) && keys %$policy == 1;
        return 'Choose what happens when an instalment is missed';
    }

    # Nothing to ask without an instalment plan, so the controller passes this step through.
    method nothing_to_ask ( $db, $run ) { !$run->data->{instalment_payment} }

    method process ( $db, $form_data, $run = undef ) {
        return { missed_payment_policy => undef } if $run && $self->nothing_to_ask( $db, $run );

        my %f = map { $_ => ( ref $form_data->{$_} ? '' : $form_data->{$_} // '' ) } qw( missed_payment grace_days );
        my $policy = { kind => $f{missed_payment}, $f{missed_payment} eq 'grace' ? ( days => $f{grace_days} ) : () };
        my $why = __PACKAGE__->refusal( $db, $run ? $run->data : {}, $policy );
        return { stay => 1, errors => [$why] } if $why;
        $policy->{days} += 0 if exists $policy->{days};    # stored as a number
        return { missed_payment_policy => $policy };
    }
}

1;
