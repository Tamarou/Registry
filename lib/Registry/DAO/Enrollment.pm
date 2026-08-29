use 5.42.0;
use Object::Pad;

class Registry::DAO::Enrollment :isa(Registry::DAO::Object) {
    use Mojo::JSON qw(decode_json);
    use Carp qw(croak);
    use Scalar::Util qw(blessed);
    use experimental 'keyword_any';
    use DateTime;

    
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
    field $refund_amount_cents :param :reader = undef;
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

    # Idempotent insert for the paid finalization paths (parent-return callback
    # and the payment_intent.succeeded webhook). Relies on the
    # enrollments_payment_dedup unique index: a duplicate (same session,
    # student, payment) is silently skipped, so calling this twice for the same
    # payment is safe.
    #
    # The arbiter is named deliberately. A bare ON CONFLICT DO NOTHING has no
    # arbiter and so absorbs a violation of every unique constraint on the
    # table, including enrollments_session_student_type_live -- which any
    # pre-existing live row for this (session, student) will hit, whatever
    # payment it belongs to. Stripe has captured by the time this runs, so
    # swallowing that insert means money taken and no enrollment, silently.
    # Only the payment replay is meant to be quiet; everything else must raise.
    sub create_for_payment ( $class, $db, $data ) {
        $db = $db->db if $db isa Registry::DAO;

        $data->{status}       //= 'active';
        $data->{student_type} //= 'family_member';
        if ( $data->{student_type} eq 'family_member' && $data->{family_member_id} ) {
            $data->{student_id} //= $data->{family_member_id};
        }
        if ( exists $data->{metadata} && ref $data->{metadata} eq 'HASH' ) {
            $data->{metadata} = { -json => $data->{metadata} };
        }

        my $inserted = $db->insert( $class->table, $data, {
            on_conflict => \'(session_id, student_id, payment_id) WHERE payment_id IS NOT NULL DO NOTHING',
            returning   => 'id',
        } )->hash;
        return $inserted->{id} if $inserted;

        # The arbiter absorbed it, so this is a replay of a row that already
        # exists. Return the id of the row that won: callers need a stable
        # handle on "the enrolment this child holds for this payment" that is
        # the same on every delivery, or anything keyed on it -- the
        # confirmation email in particular -- fires again per redelivery.
        return $db->select( $class->table, ['id'], {
            session_id => $data->{session_id},
            student_id => $data->{student_id},
            payment_id => $data->{payment_id},
        } )->hash->{id};
    }

    # Enroll a list of children into sessions with no payment: create each active
    # enrollment and queue its confirmation email. Shared by the free-enrollment
    # workflow step and the Payment step's demo path. $items is an arrayref of
    # { child_id => ..., session_id => ... }. Returns the number enrolled.
    sub enroll_children ( $class, $db, $parent_id, $items ) {
        require Registry::DAO::Notification;
        my $count = 0;
        for my $item (@$items) {
            my $enrollment = $class->create( $db, {
                session_id       => $item->{session_id},
                family_member_id => $item->{child_id},
                parent_id        => $parent_id,
                status           => 'active',
            } );
            Registry::DAO::Notification->ensure_enrollment_confirmation( $db, {
                user_id       => $parent_id,
                session_id    => $item->{session_id},
                child_id      => $item->{child_id},
                enrollment_id => $enrollment->id,
            } );
            $count++;
        }
        return $count;
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
        my $results = $db->query(q{
            SELECT DISTINCT
                fm.id as student_id,
                fm.child_name,
                fm.birth_date,
                fm.grade,
                up.name as family_name,
                up.email as family_email
            FROM enrollments e
            JOIN session_events se ON se.session_id = e.session_id
            JOIN family_members fm ON e.family_member_id = fm.id
            JOIN users u ON fm.family_id = u.id
            LEFT JOIN user_profiles up ON up.user_id = u.id
            WHERE se.event_id = ?
              AND e.status = 'active'
            ORDER BY fm.child_name
        }, $event_id);

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
    
    # The one place that answers "does this enrollment status hold a seat".
    #
    # Three consumers used to carry their own copy of this list: this class's
    # cart_seat_state classification, payment_fits_session's COUNT predicate,
    # and demote_to_waitlisted's UPDATE predicate. They agreed, which is the
    # most fragile state a duplicated rule can be in -- nothing failed if one
    # drifted, and every way of drifting is a money defect. Round 3 of the Leg 0
    # review found three separate disagreements between them about 'cancelled'.
    #
    # Deviation from the settlement spec's section 2.4, which proposes a sub
    # returning counts by category. The three consumers ask different questions
    # -- one child's state, everyone else's occupancy, and demotability -- so a
    # shared counts object would have to be reshaped at each call site. The
    # duplication was never the counting; it was this list. Sharing the list
    # gets the whole benefit for a fraction of the diff.
    #
    # Out of scope, sharing the vocabulary but not this owner:
    # get_dashboard_stats_for_parent and the family-enrollment query both count
    # ('active','pending') to answer "what is this family signed up for", which
    # is a different question that happens to have the same answer today.
    sub seat_holding_statuses ($class) { return [qw( active pending )] }

    # What does this payment already hold for this (session, child)?
    #
    # Two predicates and five answers, because every consumer of this question
    # must agree on it. A cancelled row in particular must be neither
    # re-adjudicated nor treated as a fresh demotion: doing the first
    # un-cancels an admin's drop, and doing the second owes its share a second
    # time under an idempotency key Stripe has never seen, against money the
    # enrollment's own refund_status already records as returned.
    #
    #   seated     -- active or pending. A seat in hand: leave it, and count it
    #                 against this cart's own capacity.
    #   waitlisted -- already demoted by an earlier pass. Do not re-owe.
    #   closed     -- cancelled. `enrollments_status_check` bounds this column to
    #                 pending|active|cancelled|waitlisted, so cancelled is the
    #                 whole category: a terminal drop another system owns, and
    #                 not ours to re-adjudicate.
    #   foreign    -- no row of ours, but a live row belongs to a DIFFERENT
    #                 payment: a free enrolment, an admin add, an earlier
    #                 purchase. Nothing to seat, and inserting would collide
    #                 with the live-only uniqueness rule inside a settlement
    #                 Stripe has already captured, so this cart owes its share
    #                 back instead.
    #   none       -- nothing here; adjudicate normally.
    sub cart_seat_state ($class, $db, $payment_id, $session_id, $child_id) {
        $db = $db->db if $db isa Registry::DAO;

        # Our own row first: its state is what this cart holds.
        #
        # Keyed WITHOUT student_type, deliberately, even though the foreign
        # lookup below carries it. The two queries answer different questions
        # against different rules. This one asks "does this cart already hold a
        # row here", and what decides that is enrollments_payment_dedup --
        # (session_id, student_id, payment_id), no student_type -- because that
        # arbiter is what silently absorbs our insert. Adding the column here
        # would make a row of another type invisible to us, so we would report
        # 'none', insert, and have the arbiter swallow it: money taken, no
        # enrollment. The foreign lookup asks "would the unique INDEX refuse
        # this insert", and that index does key on student_type.
        my $row = $db->select(
            $class->table, ['status'],
            {   payment_id => $payment_id,
                session_id => $session_id,
                student_id => $child_id,
            },
        )->hash;

        if ($row) {
            my $status = $row->{status} // '';
            return 'seated'
                if any { $_ eq $status } @{ $class->seat_holding_statuses };
            return 'waitlisted' if $status eq 'waitlisted';
            return 'closed';
        }

        # No row of ours -- but the child may already hold a live seat from a
        # DIFFERENT payment: a free enrolment with payment_id IS NULL, an admin
        # add, an earlier purchase. Scoping this lookup by payment_id made that
        # read as 'none', so the caller adjudicated as though the child were
        # unseated and tried to insert -- colliding with the live-only
        # uniqueness rule inside a settlement Stripe had already captured.
        #
        # 'foreign', not 'seated'. %granted credits this cart for seats it
        # holds, and this is not one of them -- the row belongs to another
        # payment. A foreign row that actually occupies a seat is already in
        # payment_fits_session's $taken, which counts every seat-holding row it
        # does not own, so crediting it here as well would count one seat twice
        # and under-count the capacity left for the next sibling in the cart.
        # Every row the uniqueness rule covers, not only the ones holding a
        # seat. The predicate mirrors enrollments_session_student_type_live
        # exactly: if the index would refuse the insert, this must report it.
        #
        # Narrowing this to the seat-holding statuses is the tempting mistake,
        # and it hides two rows that collide anyway: a waitlisted row, which
        # the platform's own capacity gate writes and nothing in lib/ ever
        # moves back out of, and an admin-created row, which carries no
        # payment_id at all. The caller then finds out by raising inside a
        # settlement Stripe has already captured.
        #
        # cancelled is excluded because the index excludes it -- that seat
        # really is free. student_type is in the predicate for the same reason:
        # the index keys on it, so a row of a different type is not a collision
        # and reporting it as one refunds a seat the insert would have granted.
        # ponytail: 'family_member' inline, because it is the only student_type
        # anything writes -- Enrollment and Waitlist both hardcode it. Widen this
        # to a parameter when a second type gets a writer, and widen
        # enrollments_payment_dedup with it, or the own-row lookup above goes
        # blind to a row of another type and the arbiter swallows our insert.
        my $elsewhere = $db->query( <<'SQL', $session_id, $child_id, 'family_member' )->hash;
            SELECT status FROM enrollments
             WHERE session_id = ? AND student_id = ? AND student_type = ?
               AND status IS DISTINCT FROM 'cancelled'
             LIMIT 1
SQL

        return $elsewhere ? 'foreign' : 'none';
    }

    # Move a paid child to the waitlist because the seat went while they paid.
    #
    # UPDATE first, INSERT only if it changed nothing. create_for_payment's
    # arbiter is DO NOTHING on (session_id, student_id, payment_id), which is
    # exactly the triple a prior pass would have written -- so on a retry, or
    # any path where the active row already exists, a plain waitlisted insert is
    # a silent no-op and the child stays enrolled in a session with no room.
    sub demote_to_waitlisted ($class, $db, $data) {
        $db = $db->db if $db isa Registry::DAO;

        my $student_id = $data->{student_id} // $data->{family_member_id};

        # Returns whether this call actually moved someone off a seat. A
        # redelivery re-runs the whole cart, and a child already waitlisted by
        # an earlier pass has already been accounted for -- re-owing a refund
        # for them charges the tenant twice for one lost seat.
        my $changed = $db->update(
            $class->table,
            { status => 'waitlisted' },
            {   session_id => $data->{session_id},
                student_id => $student_id,
                payment_id => $data->{payment_id},
                # Only a seat in hand is demotable. A predicate of
                # "not already waitlisted" also matches a cancelled row, which
                # un-cancels an admin's drop and re-owes its share.
                status     => { -in => $class->seat_holding_statuses },
            },
        )->rows;

        return 1 if $changed;

        # Nothing updated: either there is no row yet, or there is one and it is
        # already waitlisted. Only the first is a new demotion.
        my $existing = $db->select(
            $class->table, ['status'],
            {   session_id => $data->{session_id},
                student_id => $student_id,
                payment_id => $data->{payment_id},
            },
        )->hash;
        return 0 if $existing;

        $class->create_for_payment($db, { %$data, status => 'waitlisted' });
        return 1;
    }

    # Is there room for one more child from this payment, given how many seats
    # this cart has already taken in this pass?
    #
    # $already_granted is what makes a partly-fitting sibling group fill the
    # seats that exist. An earlier form compared the whole cart every time --
    # nine taken of ten with two siblings gave 9 + 2 > 10 on both iterations, so
    # both were waitlisted, both refunded, and the one free seat went unsold.
    # Asking per child, and counting the siblings already placed, fills it.
    #
    # $taken excludes this payment's own rows, because finalize_enrollment
    # writes them as 'active' as it goes and a re-check that counted them would
    # see the payment competing with itself. $already_granted adds back exactly
    # the ones this pass placed.
    #
    # NULL or zero capacity is unlimited. Zero is not hypothetical: no CHECK
    # constraint forbids it and nine live sites already read capacity with a
    # truthiness test, so a `defined` check here would refund every capacity-0
    # session at capture while all nine waved the enrollment through.
    #
    # Correct only with the session row locked and inside a transaction; the
    # caller takes that lock before calling.
    sub payment_fits_session ($class, $db, $payment, $session_id, $already_granted = 0) {
        $db = $db->db if $db isa Registry::DAO;

        # ->hash is undef when the session is not visible to this connection,
        # and the deref used to raise "Can't use an undefined value as a HASH
        # reference" from inside a settlement Stripe has already captured. There
        # is no recovery here -- treating it as unlimited seats the child and
        # the FK refuses the insert one line later -- so the only improvement
        # available is an error that says what happened.
        my $row = $db->query(
            'SELECT capacity FROM sessions WHERE id = ?', $session_id
        )->hash or die "payment_fits_session: session $session_id not found\n";
        my $capacity = $row->{capacity};
        return 1 unless $capacity;    # NULL or 0 -- unlimited

        my $taken = $db->query(
            q{SELECT COUNT(*) FROM enrollments
               WHERE session_id = ?
                 AND status = ANY(?)
                 AND (payment_id IS NULL OR payment_id != ?)},
            $session_id, $class->seat_holding_statuses, $payment->id
        )->array->[0] // 0;

        return $taken + $already_granted + 1 <= $capacity ? 1 : 0;
    }

    sub count_for_session($class, $db, $session_id, $statuses = ['active', 'pending']) {
        $db = $db->db if $db isa Registry::DAO;

        my $placeholders = join(',', ('?') x @$statuses);
        my $result = $db->query(
            "SELECT COUNT(*) FROM enrollments WHERE session_id = ? AND status IN ($placeholders)",
            $session_id, @$statuses
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

    # Get dashboard statistics for a parent (moved from ParentDashboard controller)
    sub get_dashboard_stats_for_parent($class, $db, $parent_id) {
        $db = $db->db if $db isa Registry::DAO;

        # Active enrollments count
        my $active_enrollments = $db->query(
            q{SELECT COUNT(*) FROM enrollments e
              JOIN family_members fm ON e.family_member_id = fm.id
              WHERE fm.family_id = ? AND e.status IN ('active', 'pending')},
            $parent_id
        )->array->[0] || 0;

        # Waitlist entries count
        my $waitlist_count = $db->query(
            q{SELECT COUNT(*) FROM waitlist
              WHERE parent_id = ? AND status IN ('waiting', 'offered')},
            $parent_id
        )->array->[0] || 0;

        # This month's attendance rate
        my $month_start = DateTime->now->truncate(to => 'month')->epoch;
        my $attendance_sql = q{
            SELECT
                COUNT(CASE WHEN ar.status = 'present' THEN 1 END) as present_count,
                COUNT(ar.id) as total_count
            FROM attendance_records ar
            JOIN events ev ON ar.event_id = ev.id
            JOIN family_members fm ON ar.student_id = fm.id
            WHERE fm.family_id = ?
            AND ar.marked_at >= to_timestamp(?)
        };

        my $attendance_data = $db->query($attendance_sql, $parent_id, $month_start)->hash;
        my $attendance_rate = 0;
        if ($attendance_data && $attendance_data->{total_count} > 0) {
            $attendance_rate = sprintf("%.0f",
                ($attendance_data->{present_count} / $attendance_data->{total_count}) * 100
            );
        }

        return {
            active_enrollments => $active_enrollments,
            waitlist_count => $waitlist_count,
            attendance_rate => $attendance_rate
        };
    }

    # Get active enrollments with program details for a parent (moved from ParentDashboard controller)
    sub get_active_for_parent($class, $db, $parent_id) {
        $db = $db->db if $db isa Registry::DAO;

        my $sql = q{
            SELECT
                e.id as enrollment_id,
                e.status as enrollment_status,
                e.created_at as enrolled_at,
                s.id as session_id,
                s.name as session_name,
                s.start_date,
                s.end_date,
                fm.child_name,
                COUNT(se.event_id) as total_events,
                COUNT(ar.id) as attended_events
            FROM enrollments e
            JOIN sessions s ON e.session_id = s.id
            JOIN family_members fm ON e.family_member_id = fm.id
            LEFT JOIN session_events se ON se.session_id = s.id
            LEFT JOIN attendance_records ar ON ar.event_id = se.event_id
                AND ar.student_id = e.family_member_id
                AND ar.status = 'present'
            WHERE fm.family_id = ?
            AND e.status IN ('active', 'pending')
            GROUP BY e.id, s.id, fm.id
            ORDER BY s.start_date ASC
        };

        return $db->query($sql, $parent_id)->hashes->to_array;
    }

}