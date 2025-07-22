use 5.40.2;
use Object::Pad;

class Registry::DAO::Enrollment :isa(Registry::DAO::Object) {
    use Mojo::JSON qw(decode_json);
    use Carp qw(croak);
    use experimental qw(try);
    
    field $id :param :reader;
    field $session_id :param :reader;
    field $student_id :param :reader;        # Primary reference - always points to the student entity
    field $student_type :param :reader = 'family_member'; # Type of student: family_member, individual, group_member, corporate
    field $family_member_id :param :reader = undef; # For family_member type, links to family_members table
    field $parent_id :param :reader;         # Who is responsible for payment/communication
    field $status :param :reader   //= 'pending';
    field $metadata :param :reader = {};
    field $created_at :param :reader;
    field $updated_at :param :reader;

    sub table { 'enrollments' }

    ADJUST {
        # Decode JSON metadata if it's a string
        if (defined $metadata && !ref $metadata) {
            try {
                $metadata = decode_json($metadata);
            }
            catch ($e) {
                croak "Failed to decode enrollment metadata: $e";
            }
        }
    }

    sub create ( $class, $db, $data ) {
        $data->{status} //= 'pending';
        $data->{student_type} //= 'family_member';
        
        # Encode metadata as JSON if it's a hashref
        if (exists $data->{metadata} && ref $data->{metadata} eq 'HASH') {
            $data->{metadata} = { -json => $data->{metadata} };
        }
        
        # Auto-populate fields based on student type
        if ($data->{student_type} eq 'family_member' && $data->{family_member_id}) {
            # For family members, student_id should reference the family_member
            $data->{student_id} //= $data->{family_member_id};
            
            # Auto-populate parent_id from family_member if not provided
            if (!$data->{parent_id}) {
                my $family_member = Registry::DAO::FamilyMember->find($db, { id => $data->{family_member_id} });
                $data->{parent_id} = $family_member->family_id if $family_member;
            }
        }
        
        $class->SUPER::create( $db, $data );
    }

    method update ( $db, $data, $filter = { id => $self->id } ) {
        # Encode metadata as JSON if it's a hashref
        if (exists $data->{metadata} && ref $data->{metadata} eq 'HASH') {
            $data->{metadata} = { -json => $data->{metadata} };
        }
        
        $self->SUPER::update( $db, $data, $filter );
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

    # Get the parent/responsible party for this enrollment
    method parent($db) {
        return unless $parent_id;
        Registry::DAO::User->find( $db, { id => $parent_id } );
    }
    
    # Get the student entity (type-specific)
    method student($db) {
        if ($student_type eq 'family_member') {
            require Registry::DAO::Family;
            return Registry::DAO::FamilyMember->find( $db, { id => $student_id } );
        } elsif ($student_type eq 'individual') {
            return Registry::DAO::User->find( $db, { id => $student_id } );
        } elsif ($student_type eq 'group_member') {
            # Future: return Registry::DAO::GroupMember->find( $db, { id => $student_id } );
            return { id => $student_id, type => 'group_member' }; # Placeholder
        } elsif ($student_type eq 'corporate') {
            # Future: return Registry::DAO::Employee->find( $db, { id => $student_id } );
            return { id => $student_id, type => 'corporate' }; # Placeholder
        }
        return;
    }
    
    # Get the family member (for family_member type enrollments)
    method family_member($db) {
        return unless $student_type eq 'family_member' && $family_member_id;
        require Registry::DAO::Family;
        Registry::DAO::FamilyMember->find( $db, { id => $family_member_id } );
    }
    
    # Helper methods for student types
    method is_family_member { $student_type eq 'family_member' }
    method is_individual    { $student_type eq 'individual' }
    method is_group_member  { $student_type eq 'group_member' }
    method is_corporate     { $student_type eq 'corporate' }

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