use 5.40.2;
use Object::Pad;

class Registry::DAO::DropRequest :isa(Registry::DAO::Object) {
    use Carp qw(croak);
    use Scalar::Util qw(blessed);

    field $id :param :reader;
    field $enrollment_id :param :reader;
    field $requested_by :param :reader;
    field $reason :param :reader;
    field $refund_requested :param :reader = 0;
    field $refund_amount_requested :param :reader = undef;
    field $status :param :reader = 'pending';
    field $admin_notes :param :reader = '';
    field $processed_by :param :reader = undef;
    field $processed_at :param :reader = undef;
    field $created_at :param :reader;
    field $updated_at :param :reader;

    sub table { 'drop_requests' }

    sub create ( $class, $db, $data ) {
        $data->{status} //= 'pending';
        $data->{refund_requested} //= 0;

        $class->SUPER::create( $db, $data );
    }

    # Get the enrollment this request is for
    method enrollment($db) {
        Registry::DAO::Enrollment->find( $db, { id => $enrollment_id } );
    }

    # Get the user who made the request
    method requester($db) {
        Registry::DAO::User->find( $db, { id => $requested_by } );
    }

    # Get the admin who processed the request
    method processor($db) {
        return unless $processed_by;
        Registry::DAO::User->find( $db, { id => $processed_by } );
    }

    # Approve the drop request
    method approve($db, $admin_user, $notes = '', $refund_amount = undef) {
        my $admin_id = blessed($admin_user) ? $admin_user->id : $admin_user->{id};

        # Start transaction to ensure atomicity
        my $tx = $db->begin;

        # Update drop request status
        $self->update($db, {
            status => 'approved',
            admin_notes => $notes,
            processed_by => $admin_id,
            processed_at => \'now()'
        });

        # Update enrollment to cancelled
        my $enrollment = $self->enrollment($db);
        $enrollment->update($db, {
            status => 'cancelled',
            drop_reason => $reason,
            dropped_at => \'now()',
            dropped_by => $admin_id,
            refund_status => $refund_amount ? 'pending' : 'not_applicable',
            refund_amount => $refund_amount ? sprintf('%.2f', $refund_amount) : undef
        });

        $tx->commit;

        return $self;
    }

    # Deny the drop request
    method deny($db, $admin_user, $notes) {
        my $admin_id = blessed($admin_user) ? $admin_user->id : $admin_user->{id};

        $self->update($db, {
            status => 'denied',
            admin_notes => $notes,
            processed_by => $admin_id,
            processed_at => \'now()'
        });

        return $self;
    }

    # Status check methods
    method is_pending() { $status eq 'pending' }
    method is_approved() { $status eq 'approved' }
    method is_denied() { $status eq 'denied' }

    # Request drop for an enrollment (with parent permission validation)
    sub request_for_enrollment($class, $db, $enrollment_id, $user, $reason = 'Parent requested drop', $refund_requested = 0) {
        $db = $db->db if $db isa Registry::DAO;

        # Find enrollment using DAO
        my $enrollment = Registry::DAO::Enrollment->find($db, { id => $enrollment_id });
        return { error => 'Enrollment not found' } unless $enrollment;

        # Verify parent owns this enrollment via family member
        my $family_member = $db->select('family_members', '*', {
            id => $enrollment->family_member_id,
            family_id => $user->{id}
        })->hash;

        return { error => 'Forbidden - you do not own this enrollment' } unless $family_member;

        # Check if drop is allowed and process accordingly
        if ($enrollment->can_drop($db, $user)) {
            # Immediate drop allowed (session hasn't started)
            $enrollment->request_drop($db, $user, $reason, $refund_requested);
            return {
                success => 1,
                message => 'Enrollment cancelled successfully. Waitlist will be processed automatically.',
                immediate => 1
            };
        } else {
            # Drop request requires admin approval (session has started)
            my $drop_request = $enrollment->request_drop($db, $user, $reason, $refund_requested);
            return {
                success => 1,
                message => 'Drop request submitted for admin approval',
                immediate => 0,
                drop_request => $drop_request
            };
        }
    }

    # Get all pending drop requests
    sub get_pending($class, $db) {
        my @requests = $class->find( $db, { status => 'pending' } );
        return \@requests;
    }

    # Get all drop requests with detailed information for admin dashboard
    sub get_detailed_requests($class, $db, $status_filter = 'all', $limit = 50) {
        $db = $db->db if $db isa Registry::DAO;

        my $sql = q{
            SELECT
                dr.id,
                dr.enrollment_id,
                dr.requested_by,
                dr.reason,
                dr.refund_requested,
                dr.refund_amount_requested,
                dr.status,
                dr.admin_notes,
                dr.processed_by,
                dr.processed_at,
                dr.created_at,
                dr.updated_at,
                -- Enrollment details
                e.status as enrollment_status,
                -- Session details
                s.name as session_name,
                s.start_date,
                s.end_date,
                -- Program details
                p.name as program_name,
                -- Location details
                l.name as location_name,
                -- Family member details
                fm.child_name,
                -- Parent details
                u.name as parent_name,
                u.email as parent_email,
                -- Admin details (if processed)
                au.name as admin_name,
                -- Request timing
                EXTRACT(EPOCH FROM dr.created_at) as created_at_epoch,
                EXTRACT(EPOCH FROM dr.processed_at) as processed_at_epoch,
                EXTRACT(DAYS FROM (now() - dr.created_at)) as days_since_request
            FROM drop_requests dr
            JOIN enrollments e ON dr.enrollment_id = e.id
            JOIN sessions s ON e.session_id = s.id
            JOIN projects p ON s.project_id = p.id
            LEFT JOIN locations l ON s.location_id = l.id
            LEFT JOIN family_members fm ON e.family_member_id = fm.id
            JOIN users u ON fm.family_id = u.id
            LEFT JOIN users au ON dr.processed_by = au.id
        };

        my @where_conditions;
        my @params;

        if ($status_filter eq 'pending') {
            push @where_conditions, "dr.status = 'pending'";
        } elsif ($status_filter eq 'approved') {
            push @where_conditions, "dr.status = 'approved'";
        } elsif ($status_filter eq 'denied') {
            push @where_conditions, "dr.status = 'denied'";
        } elsif ($status_filter ne 'all') {
            push @where_conditions, "dr.status = 'pending'"; # Default to pending
        }

        if (@where_conditions) {
            $sql .= ' WHERE ' . join(' AND ', @where_conditions);
        }

        $sql .= ' ORDER BY dr.created_at DESC';

        if ($limit) {
            $sql .= ' LIMIT ?';
            push @params, $limit;
        }

        my $results = $db->query($sql, @params)->hashes->to_array;

        # Add computed fields for UI
        for my $request (@$results) {
            # Determine urgency based on age
            if ($request->{days_since_request} == 0) {
                $request->{urgency} = 'today';
            } elsif ($request->{days_since_request} <= 2) {
                $request->{urgency} = 'recent';
            } elsif ($request->{days_since_request} <= 7) {
                $request->{urgency} = 'normal';
            } else {
                $request->{urgency} = 'old';
            }

            # Session status relative to drop request
            if ($request->{start_date}) {
                my $session_start = $request->{start_date};
                if ($session_start =~ /^(\d{4})-(\d{2})-(\d{2})/) {
                    my $session_date = DateTime->new(year => $1, month => $2, day => $3);
                    my $now = DateTime->now;

                    if ($session_date > $now) {
                        $request->{session_status} = 'upcoming';
                    } elsif ($session_date->ymd eq $now->ymd) {
                        $request->{session_status} = 'today';
                    } else {
                        $request->{session_status} = 'ongoing';
                    }
                }
            }

            # Format refund amount for display
            if ($request->{refund_amount_requested}) {
                $request->{refund_amount_display} = sprintf('$%.2f', $request->{refund_amount_requested} / 100);
            }

            # Convert timestamps for display
            $request->{created_at} = $request->{created_at_epoch};
            $request->{processed_at} = $request->{processed_at_epoch} if $request->{processed_at_epoch};
        }

        return $results;
    }
}