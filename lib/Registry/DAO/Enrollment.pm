use 5.40.2;
use Object::Pad;

class Registry::DAO::Enrollment :isa(Registry::DAO::Object) {
    field $id :param :reader;
    field $session_id :param :reader;
    field $student_id :param :reader;
    field $family_member_id :param :reader;
    field $status :param :reader   //= 'pending';
    # TODO: Enrollment class needs:
    # - Remove //= {} default
    # - Add BUILD for JSON decoding
    # - Use { -json => $metadata } in create/update
    # - Add explicit metadata() accessor
    field $metadata :param :reader //= {};
    field $created_at :param :reader;
    field $updated_at :param :reader;

    use constant table => 'enrollments';

    sub create ( $class, $db, $data ) {
        $data->{status} //= 'pending';
        $class->SUPER::create( $db, $data );
    }

    # Get the session this enrollment belongs to
    method session($db) {
        Registry::DAO::Session->find( $db, { id => $session_id } );
    }
    
    # Get all students enrolled for a specific event
    sub get_students_for_event($class, $db, $event_id, %opts) {
        my $tenant = $opts{tenant} // 'public';
        
        my $results = $db->query(qq{
            SELECT DISTINCT 
                fm.id as student_id,
                fm.child_name,
                fm.birth_date,
                fm.grade,
                u.name as family_name,
                u.email as family_email
            FROM registry.enrollments e
            JOIN registry.sessions s ON e.session_id = s.id
            JOIN registry.events ev ON ev.session_id = s.id
            JOIN registry.family_members fm ON e.family_member_id = fm.id
            JOIN registry.users u ON fm.family_id = u.id
            WHERE ev.id = ? 
              AND e.status = 'active'
              AND u.tenant = ?
            ORDER BY fm.child_name
        }, $event_id, $tenant);
        
        return $results->hashes->to_array;
    }

    # Get the student associated with this enrollment
    method student($db) {
        Registry::DAO::User->find( $db, { id => $student_id } );
    }
    
    # Get the family member associated with this enrollment
    method family_member($db) {
        return unless $family_member_id;
        require Registry::DAO::Family;
        Registry::DAO::FamilyMember->find( $db, { id => $family_member_id } );
    }

    # Helper methods for enrollment status
    method is_active     { $status eq 'active' }
    method is_waitlisted { $status eq 'waitlisted' }
    method is_cancelled  { $status eq 'cancelled' }
    method is_pending    { $status eq 'pending' }

    # Status transition methods
    my $update_status = method( $db, $new_status ) {
        $status = $new_status;
        return $self->update( $db, { status => $new_status } );
    };

    method activate($db) { $self->$update_status( $db, 'active' ) }
    method waitlist($db) { $self->$update_status( $db, 'waitlisted' ) }
    method cancel($db)   { $self->$update_status( $db, 'cancelled' ) }
    method pend($db)     { $self->$update_status( $db, 'pending' ) }

}