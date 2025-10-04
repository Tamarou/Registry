use 5.40.2;
use Object::Pad;

class Registry::DAO::WorkflowSteps::SelectEnrollmentForTransfer :isa(Registry::DAO::WorkflowStep) {
    use experimental qw(try);

    method process($db, $form_data, $run_data = {}) {
        my $user = $run_data->{user} or die "User required for enrollment selection";

        # If enrollment_id is provided (e.g., from dashboard link), validate and use it
        if (my $enrollment_id = $form_data->{enrollment_id} || $run_data->{enrollment_id}) {
            my $enrollment = Registry::DAO::Enrollment->find($db, { id => $enrollment_id });
            return { error => 'Enrollment not found' } unless $enrollment;

            # Verify parent owns this enrollment via family member
            my $family_member = $db->select('family_members', '*', {
                id => $enrollment->family_member_id,
                family_id => $user->{id}
            })->hash;

            return { error => 'You do not have permission to transfer this enrollment' } unless $family_member;

            # Check if transfer is allowed
            unless ($enrollment->can_transfer($db, $user)) {
                return { error => 'Transfer requests are not allowed for this enrollment' };
            }

            # Store enrollment data for next steps
            return {
                next_step => 'select-target-session',
                data => {
                    enrollment_id => $enrollment_id,
                    enrollment => $enrollment,
                    family_member => $family_member
                }
            };
        }

        # If no enrollment_id provided, show selection form
        # Get all transferable enrollments for this parent
        my $transferable_enrollments = $self->_get_transferable_enrollments($db, $user->{id});

        return {
            template_data => {
                enrollments => $transferable_enrollments
            }
        };
    }

    method _get_transferable_enrollments($db, $parent_id) {
        my $sql = q{
            SELECT
                e.id as enrollment_id,
                e.status as enrollment_status,
                s.id as session_id,
                s.name as session_name,
                s.start_date,
                s.end_date,
                p.name as program_name,
                l.name as location_name,
                fm.child_name
            FROM enrollments e
            JOIN sessions s ON e.session_id = s.id
            JOIN programs p ON s.project_id = p.id
            LEFT JOIN locations l ON s.location_id = l.id
            JOIN family_members fm ON e.family_member_id = fm.id
            WHERE fm.family_id = ?
            AND e.status IN ('active', 'pending')
            AND e.transfer_status = 'none'
            AND s.start_date > NOW()
            ORDER BY s.start_date ASC
        };

        return $db->query($sql, $parent_id)->hashes->to_array;
    }
}