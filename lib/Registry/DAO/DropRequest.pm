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
        $db = $db->db if $db isa Registry::DAO;

        my $admin_id = blessed($admin_user) ? $admin_user->id : $admin_user->{id};

        # Update request status
        $self->update($db, {
            status => 'approved',
            admin_notes => $notes,
            processed_by => $admin_id,
            processed_at => \'now()'
        });

        # Process the actual drop
        my $enrollment = $self->enrollment($db);
        if ($enrollment) {
            $enrollment->update($db, {
                status => 'cancelled',
                drop_reason => $reason,
                dropped_at => \'now()',
                dropped_by => $admin_id,
                refund_status => $refund_requested ? 'pending' : 'none',
                refund_amount => $refund_amount
            });

            # Trigger waitlist processing
            require Registry::DAO::Waitlist;
            Registry::DAO::Waitlist->process_waitlist($db, $enrollment->session_id);
        }

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
}