# ABOUTME: Registration workflow decision step -- routes by whether payment is due.
# ABOUTME: $0 enrollment total -> free-enrollment; >$0 -> payment. Independent of STRIPE_SECRET_KEY.
use 5.42.0;

use Object::Pad;

class Registry::DAO::WorkflowSteps::CheckEnrollmentPayment :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Payment;

    method process ( $db, $form_data, $run = undef ) {
        $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };

        # Whether payment is required is a property of the program's pricing, not
        # of the deployment environment. Compute the total the same way the
        # payment step does, then branch to the matching step.
        my $enrollment_data = {
            children           => $run->data->{children}           || [],
            session_selections => $run->data->{session_selections} || {},
        };
        my $info  = Registry::DAO::Payment->calculate_enrollment_total( $db, $enrollment_data );
        my $total = $info->{total} // 0;

        return { next_step => $total > 0 ? 'payment' : 'free-enrollment' };
    }
}
