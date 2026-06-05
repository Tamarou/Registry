# ABOUTME: Registration workflow step that enrolls children with no payment ($0 programs).
# ABOUTME: Reached from CheckEnrollmentPayment when the enrollment total is zero.
use 5.42.0;

use Object::Pad;

class Registry::DAO::WorkflowSteps::FreeEnrollment :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Enrollment;

    method process ( $db, $form_data, $run = undef ) {
        $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };

        my $user_id = $run->data->{user_id} or die "No user_id in workflow data";
        my $items   = $run->data->{enrollment_items} || [];

        Registry::DAO::Enrollment->enroll_children( $db, $user_id, $items );

        # Advance straight to the shared "Registration Complete" page; this step
        # renders nothing of its own.
        return { next_step => 'complete' };
    }
}
