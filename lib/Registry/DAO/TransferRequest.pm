use 5.40.2;
use Object::Pad;

class Registry::DAO::TransferRequest :isa(Registry::DAO::Object) {
    use Carp qw(croak);
    use Scalar::Util qw(blessed);

    field $id :param :reader;
    field $enrollment_id :param :reader;
    field $target_session_id :param :reader;
    field $requested_by :param :reader;
    field $reason :param :reader;
    field $status :param :reader = 'pending';
    field $admin_notes :param :reader = '';
    field $processed_by :param :reader = undef;
    field $processed_at :param :reader = undef;
    field $created_at :param :reader;
    field $updated_at :param :reader;

    sub table { 'transfer_requests' }

    sub create ( $class, $db, $data ) {
        $data->{status} //= 'pending';

        $class->SUPER::create( $db, $data );
    }

    # Get the enrollment this request is for
    method enrollment($db) {
        Registry::DAO::Enrollment->find( $db, { id => $enrollment_id } );
    }

    # Get the target session
    method to_session($db) {
        Registry::DAO::Session->find( $db, { id => $target_session_id } );
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

    # Approve the transfer request using workflow
    method approve($db, $admin_user, $notes = '') {
        $db = $db->db if $db isa Registry::DAO;

        # Find the transfer request processing workflow
        require Registry::DAO;
        my $dao = Registry::DAO->new(db => $db);
        my ($workflow) = $dao->find(Workflow => { slug => 'transfer-request-processing' });

        unless ($workflow) {
            die "Transfer request processing workflow not found. Please ensure workflows are imported.";
        }

        # Prepare workflow data
        my $workflow_data = {
            transfer_request_id => $id,
            admin_user => $admin_user,
            admin_notes => $notes
        };

        # Execute workflow
        my $run = $workflow->new_run($db);
        $run->update_data($db, $workflow_data);
        $run->process($db, $workflow->first_step($db), $workflow_data);

        return $self;
    }

    # Deny the transfer request
    method deny($db, $admin_user, $notes) {
        $db = $db->db if $db isa Registry::DAO;

        my $admin_id = blessed($admin_user) ? $admin_user->id : $admin_user->{id};

        # Update request status
        $self->update($db, {
            status => 'denied',
            admin_notes => $notes,
            processed_by => $admin_id,
            processed_at => \'now()'
        });

        # Reset enrollment transfer status to 'none'
        my $enrollment = $self->enrollment($db);
        if ($enrollment) {
            $enrollment->update($db, {
                transfer_status => 'none'
            });
        }

        return $self;
    }

    # Status check methods
    method is_pending() { $status eq 'pending' }
    method is_approved() { $status eq 'approved' }
    method is_denied() { $status eq 'denied' }

    # Get all pending transfer requests
    sub get_pending($class, $db) {
        my @requests = $class->find( $db, { status => 'pending' } );
        return \@requests;
    }

    # Get all transfer requests with detailed information for admin dashboard
    sub get_detailed_requests($class, $db, $status_filter = 'all') {
        $db = $db->db if $db isa Registry::DAO;

        my $where_clause = '';
        my @params = ();

        if ($status_filter ne 'all') {
            $where_clause = 'WHERE tr.status = ?';
            push @params, $status_filter;
        }

        my $sql = qq{
            SELECT
                tr.id,
                tr.enrollment_id,
                tr.target_session_id,
                tr.requested_by,
                tr.reason,
                tr.status,
                tr.admin_notes,
                tr.processed_by,
                tr.processed_at,
                tr.created_at,
                tr.updated_at,
                -- Enrollment details
                e.student_id,
                e.family_member_id,
                e.session_id as from_session_id,
                -- From session details
                fs.name as from_session_name,
                fp.name as from_program_name,
                fl.name as from_location_name,
                -- To session details
                ts.name as to_session_name,
                tp.name as to_program_name,
                tl.name as to_location_name,
                -- Student details
                fm.child_name,
                -- Parent details
                u.name as parent_name,
                u.email as parent_email,
                -- Admin details (if processed)
                au.name as admin_name,
                -- Request timing
                EXTRACT(EPOCH FROM tr.created_at) as created_at_epoch,
                EXTRACT(EPOCH FROM tr.processed_at) as processed_at_epoch,
                EXTRACT(DAYS FROM (now() - tr.created_at)) as days_since_request
            FROM transfer_requests tr
            JOIN enrollments e ON tr.enrollment_id = e.id
            JOIN sessions fs ON e.session_id = fs.id
            JOIN sessions ts ON tr.target_session_id = ts.id
            JOIN projects fp ON fs.project_id = fp.id
            JOIN projects tp ON ts.project_id = tp.id
            LEFT JOIN locations fl ON fs.location_id = fl.id
            LEFT JOIN locations tl ON ts.location_id = tl.id
            JOIN family_members fm ON e.family_member_id = fm.id
            JOIN users u ON fm.family_id = u.id
            LEFT JOIN users au ON tr.processed_by = au.id
            $where_clause
            ORDER BY tr.created_at DESC
        };

        my $results = $db->query($sql, @params)->hashes->to_array;

        # Add computed fields for UI
        for my $request (@$results) {
            # Determine urgency based on age
            if ($request->{days_since_request} == 0) {
                $request->{urgency} = 'today';
            } elsif ($request->{days_since_request} <= 3) {
                $request->{urgency} = 'recent';
            } elsif ($request->{days_since_request} >= 7) {
                $request->{urgency} = 'old';
            } else {
                $request->{urgency} = 'normal';
            }

            # Convert timestamps for display
            $request->{created_at} = $request->{created_at_epoch};
            $request->{processed_at} = $request->{processed_at_epoch} if $request->{processed_at_epoch};
        }

        return $results;
    }
}