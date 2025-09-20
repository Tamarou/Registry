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

    # Approve the drop request using workflow
    method approve($db, $admin_user, $notes = '', $refund_amount = undef) {
        $db = $db->db if $db isa Registry::DAO;

        # Find the drop request processing workflow
        require Registry::DAO;
        my $dao = Registry::DAO->new(db => $db);
        my ($workflow) = $dao->find(Workflow => { slug => 'drop-request-processing' });

        unless ($workflow) {
            die "Drop request processing workflow not found. Please ensure workflows are imported.";
        }

        # Prepare workflow data
        my $workflow_data = {
            drop_request_id => $id,
            admin_user => $admin_user,
            admin_notes => $notes,
            reason => $reason,
            refund_requested => $refund_requested,
            refund_amount => $refund_amount
        };

        # Execute workflow
        my $run = $workflow->new_run($db);
        $run->update_data($db, $workflow_data);
        $run->process($db, $workflow->first_step($db), $workflow_data);

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