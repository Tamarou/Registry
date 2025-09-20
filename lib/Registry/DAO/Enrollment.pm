use 5.40.2;
use Object::Pad;

class Registry::DAO::Enrollment :isa(Registry::DAO::Object) {
    use Mojo::JSON qw(decode_json);
    use Carp qw(croak);
    use Scalar::Util qw(blessed);
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

    # Drop and transfer fields
    field $drop_reason :param :reader = undef;
    field $dropped_at :param :reader = undef;
    field $dropped_by :param :reader = undef;
    field $refund_status :param :reader = 'none';
    field $refund_amount :param :reader = undef;
    field $transfer_to_session_id :param :reader = undef;
    field $transfer_status :param :reader = 'none';

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
    
    # Count enrollments for a session by status
    sub count_for_session($class, $db, $session_id, $statuses = ['active', 'pending']) {
        $db = $db->db if $db isa Registry::DAO;

        my $status_list = join(',', map { "'$_'" } @$statuses);
        my $result = $db->query(
            "SELECT COUNT(*) FROM enrollments WHERE session_id = ? AND status IN ($status_list)",
            $session_id
        );
        return $result->array->[0] || 0;
    }

    # Check if enrollment can be dropped by the specified user
    method can_drop($db, $user) {
        my $session = $self->session($db);

        # Admin can always drop
        my $user_role = blessed($user) ? $user->user_type : $user->{role};
        return 1 if $user_role eq 'admin';

        # Parents can only drop before session starts
        return !$session->has_started();
    }

    # Request to drop enrollment (creates admin approval request if needed)
    method request_drop($db, $user, $reason, $refund_requested = 0) {
        $db = $db->db if $db isa Registry::DAO;

        my $session = $self->session($db);

        # If session has started and user is not admin, create drop request
        my $user_role = blessed($user) ? $user->user_type : $user->{role};
        my $user_id = blessed($user) ? $user->id : $user->{id};

        if ($session->has_started && $user_role ne 'admin') {
            require Registry::DAO::DropRequest;
            return Registry::DAO::DropRequest->create($db, {
                enrollment_id => $id,
                requested_by => $user_id,
                reason => $reason,
                refund_requested => $refund_requested ? 1 : 0,
                status => 'pending'
            });
        }

        # Process immediate drop (before session starts or admin)
        return $self->_process_immediate_drop($db, $user, $reason);
    }

    # Process immediate drop (private method)
    method _process_immediate_drop($db, $user, $reason) {
        $db = $db->db if $db isa Registry::DAO;

        my $user_id = blessed($user) ? $user->id : $user->{id};

        # Update enrollment status and drop information
        $self->update($db, {
            status => 'cancelled',
            drop_reason => $reason,
            dropped_at => \'now()',
            dropped_by => $user_id,
            refund_status => 'none'
        });

        # Trigger waitlist processing if session is full
        my $session = $self->session($db);
        if ($session) {
            require Registry::DAO::Waitlist;
            Registry::DAO::Waitlist->process_waitlist($db, $session_id);
        }

        return $self;
    }

    # Transfer enrollment to another session (requires admin approval)
    method request_transfer($db, $user, $target_session_id, $reason) {
        $db = $db->db if $db isa Registry::DAO;

        # Check if enrollment already has a pending transfer request
        if ($transfer_status eq 'requested') {
            return { error => 'Enrollment already has a pending transfer request' };
        }

        # Verify target session exists and is valid for transfer
        my $target_session = Registry::DAO::Session->find($db, { id => $target_session_id });
        return { error => 'Target session not found' } unless $target_session;

        # Check if target session is full
        my $target_enrollment_count = Registry::DAO::Enrollment->count_for_session($db, $target_session_id, ['active', 'pending']);
        if ($target_session->capacity && $target_enrollment_count >= $target_session->capacity) {
            return { error => 'Target session is full' };
        }

        # Transfers always require admin approval per MVP requirements
        require Registry::DAO::TransferRequest;
        my $transfer_request = Registry::DAO::TransferRequest->create($db, {
            enrollment_id => $id,
            target_session_id => $target_session_id,
            requested_by => (blessed($user) ? $user->id : $user->{id}),
            reason => $reason,
            status => 'pending'
        });

        # Update enrollment to show transfer is requested
        $self->update($db, { transfer_status => 'requested' });

        # Update the field in the object instance
        $transfer_status = 'requested';

        return { success => 1, transfer_request => $transfer_request };
    }

    # Check if enrollment can be transferred
    method can_transfer($db, $user) {
        # Admin can always transfer
        my $user_role = blessed($user) ? $user->user_type : $user->{role};
        return 1 if $user_role eq 'admin';

        # Parents can request transfers only for their own children
        if ($user_role eq 'parent') {
            my $user_id = blessed($user) ? $user->id : $user->{id};
            return $parent_id eq $user_id;
        }

        # Default: no permission
        return 0;
    }

    # Process approved transfer (admin action)
    method process_transfer($db, $target_session_id, $admin_user) {
        $db = $db->db if $db isa Registry::DAO;

        my $admin_id = blessed($admin_user) ? $admin_user->id : $admin_user->{id};
        my $original_session_id = $session_id;

        # Update enrollment to new session
        $self->update($db, {
            session_id => $target_session_id,
            transfer_to_session_id => $target_session_id,
            transfer_status => 'completed'
        });

        # Process waitlist for the original session (spot opened up)
        require Registry::DAO::Waitlist;
        Registry::DAO::Waitlist->process_waitlist($db, $original_session_id);

        return $self;
    }

    # Helper methods for transfer status
    method is_transfer_pending { $transfer_status eq 'requested' }
    method is_transfer_completed { $transfer_status eq 'completed' }
    method has_transfer_request { $transfer_status ne 'none' }

}