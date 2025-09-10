use 5.40.2;
use utf8;
use experimental qw(try);
use Object::Pad;

class Registry::DAO::Waitlist :isa(Registry::DAO::Object) {
    use Carp qw( croak );
    
    field $id :param :reader;
    field $session_id :param :reader;
    field $location_id :param :reader;
    field $student_id :param :reader;
    field $parent_id :param :reader;
    field $family_member_id :param :reader;
    field $position :param :reader;
    field $status :param :reader = 'waiting';
    field $offered_at :param :reader;
    field $expires_at :param :reader;
    field $notes :param :reader = '';
    field $created_at :param :reader;
    field $updated_at :param :reader;
    
    sub table { 'waitlist' }
    
    ADJUST {
        # Validate status
        unless ($status && $status =~ /^(waiting|offered|expired|declined)$/) {
            croak "Invalid waitlist status: must be 'waiting', 'offered', 'expired', or 'declined'";
        }
    }
    
    sub create ($class, $db, $data) {
        $db = $db->db if $db isa Registry::DAO;
        # Validate required fields
        for my $field (qw(session_id location_id student_id parent_id)) {
            croak "Missing required field: $field" unless $data->{$field};
        }
        
        # Set default status
        $data->{status} //= 'waiting';
        
        # Get next position if not provided
        if (!defined $data->{position}) {
            my $sql = 'SELECT get_next_waitlist_position(?)';
            $data->{position} = $db->query($sql, $data->{session_id})->array->[0];
        }
        
        $class->SUPER::create($db, $data);
    }
    
    # Join the waitlist
    sub join_waitlist ($class, $db, $session_id, $location_id, $student_id, $parent_id, $notes = undef) {
        # Check if already enrolled
        if ($class->is_student_enrolled($db, $session_id, $student_id)) {
            croak "Student is already enrolled in this session";
        }
        
        # Check if already on waitlist
        if ($class->is_student_waitlisted($db, $session_id, $student_id)) {
            croak "Student is already on the waitlist for this session";
        }
        
        return $class->create($db, {
            session_id => $session_id,
            location_id => $location_id,
            student_id => $student_id,
            parent_id => $parent_id,
            defined $notes ? (notes => $notes) : ()
        });
    }
    
    # Process waitlist when a spot opens up
    sub process_waitlist ($class, $db, $session_id, $hours_to_respond = 48) {
        $db = $db->db if $db isa Registry::DAO;
        # Find next waiting person
        my $next = $db->select(
            $class->table,
            undef,
            { session_id => $session_id, status => 'waiting' },
            { -asc => 'position' }
        )->hash;
        
        return unless $next;
        
        # Create waitlist entry object
        my $entry = $class->new(%$next);
        
        # Calculate expiration time using SQL
        my $expires_at = $db->query("SELECT NOW() + INTERVAL '$hours_to_respond hours'")->array->[0];
        
        # Update to offered status
        $entry->update($db, {
            status => 'offered',
            offered_at => 'now()',
            expires_at => $expires_at
        });
        
        # Refresh the object to get updated values
        return $class->find($db, { id => $entry->id });
    }
    
    # Check and expire old offers
    sub expire_old_offers ($class, $db) {
        $db = $db->db if $db isa Registry::DAO;
        my $sql = q{
            UPDATE waitlist 
            SET status = 'expired'
            WHERE status = 'offered' 
            AND expires_at < ?
            RETURNING *
        };
        
        my $current_time = $db->query('SELECT NOW()')->array->[0];
        my $results = $db->query($sql, $current_time)->hashes;
        return [ map { $class->new(%$_) } @$results ];
    }
    
    # Get waitlist for a session
    sub get_session_waitlist ($class, $db, $session_id, $status = 'waiting') {
        $db = $db->db if $db isa Registry::DAO;
        my $where = { session_id => $session_id };
        $where->{status} = $status if $status;
        
        my $results = $db->select(
            $class->table,
            undef,
            $where,
            { -asc => 'position' }
        )->hashes;
        
        return [ map { $class->new(%$_) } @$results ];
    }
    
    # Get waitlist position for a student
    sub get_student_position ($class, $db, $session_id, $student_id) {
        $db = $db->db if $db isa Registry::DAO;
        
        # Calculate dynamic position based on waiting entries only
        # This accounts for gaps caused by accepted/declined entries
        my $sql = q{
            SELECT dynamic_position 
            FROM (
                SELECT student_id, ROW_NUMBER() OVER (ORDER BY created_at) as dynamic_position
                FROM waitlist 
                WHERE session_id = ? 
                AND status = 'waiting'
            ) positions
            WHERE student_id = ?
        };
        
        my $result = $db->query($sql, $session_id, $student_id)->hash;
        return $result ? $result->{dynamic_position} : undef;
    }
    
    # Check if student is already enrolled
    sub is_student_enrolled ($class, $db, $session_id, $student_id) {
        $db = $db->db if $db isa Registry::DAO;
        require Registry::DAO::Event;
        
        my $count = $db->select('enrollments', 'COUNT(*)', {
            session_id => $session_id,
            student_id => $student_id,
            status => ['active', 'pending']
        })->array->[0];
        
        return $count > 0;
    }
    
    # Check if student is already waitlisted
    sub is_student_waitlisted ($class, $db, $session_id, $student_id) {
        $db = $db->db if $db isa Registry::DAO;
        my $count = $db->select($class->table, 'COUNT(*)', {
            session_id => $session_id,
            student_id => $student_id,
            status => ['waiting', 'offered']
        })->array->[0];
        
        return $count > 0;
    }
    
    # Accept waitlist offer
    method accept_offer ($db) {
        croak "Can only accept offers with status 'offered'" unless $status eq 'offered';
        # Check expiration via database query
        $db = $db->db if $db isa Registry::DAO;
        my $is_expired = $db->query('SELECT ? < NOW()', $expires_at)->array->[0];
        croak "Offer has expired" if $expires_at && $is_expired;
        
        # Start transaction
        my $tx = $db->begin;
        
        try {
            # Create enrollment
            require Registry::DAO::Enrollment;
            Registry::DAO::Enrollment->create($db, {
                session_id => $session_id,
                student_id => $family_member_id || $student_id,  # Use family_member_id as primary student reference
                family_member_id => $family_member_id,
                parent_id => $parent_id,
                student_type => 'family_member',
                status => 'pending',
                metadata => { from_waitlist => 1 }
            });
            
            # Update waitlist status  
            $self->update($db, { status => 'declined' }); # Use 'declined' to keep history
            
            # Note: No need to reorder positions since get_student_position calculates dynamically
            
            $tx->commit;
        }
        catch ($e) {
            croak "Failed to accept waitlist offer: $e";
        }
        
        return $self;
    }
    
    # Decline waitlist offer
    method decline_offer ($db) {
        croak "Can only decline offers with status 'offered'" unless $status eq 'offered';
        
        # Start transaction for consistency
        my $tx = $db->db->begin;
        
        try {
            # Update status to declined
            $self->update($db, { status => 'declined' });
            
            # Only reorder if this entry had a position that would affect other entries
            # For offered entries, we don't need to reorder since they maintain their original position
            # and other entries haven't moved
            
            $tx->commit;
        }
        catch ($e) {
            croak "Failed to decline waitlist offer: $e";
        }
        
        # Process next person on waitlist
        return Registry::DAO::Waitlist->process_waitlist($db, $session_id);
    }
    
    # Get related objects
    method session ($db) {
        require Registry::DAO::Event;
        Registry::DAO::Session->find($db, { id => $session_id });
    }
    
    method location ($db) {
        require Registry::DAO;
        Registry::DAO::Location->find($db, { id => $location_id });
    }
    
    method student ($db) {
        require Registry::DAO;
        Registry::DAO::User->find($db, { id => $student_id });
    }
    
    method parent ($db) {
        require Registry::DAO;
        Registry::DAO::User->find($db, { id => $parent_id });
    }
    
    method family_member ($db) {
        return unless $family_member_id;
        require Registry::DAO::Family;
        Registry::DAO::FamilyMember->find($db, { id => $family_member_id });
    }
    
    # Helper methods
    method is_waiting  { $status eq 'waiting' }
    method is_offered  { $status eq 'offered' }
    method is_expired  { $status eq 'expired' }
    method is_declined { $status eq 'declined' }
    
    method offer_is_active ($db) {
        return 0 unless $status eq 'offered';
        if ($expires_at) {
            my $is_expired = $db->query('SELECT ? < NOW()', $expires_at)->array->[0];
            return 0 if $is_expired;
        }
        return 1;
    }
    
    # Helper method to reorder positions after a waitlist entry is removed
    method _reorder_positions_after_removal ($db, $session_id, $removed_position) {
        $db = $db->db if $db isa Registry::DAO;
        
        # Simple approach: just subtract 1 from all positions greater than removed position
        # This is safer and avoids constraint violations
        my $sql = q{
            UPDATE waitlist 
            SET position = position - 1
            WHERE session_id = ? 
            AND position > ? 
            AND status = 'waiting'
        };
        
        $db->query($sql, $session_id, $removed_position);
    }
    
    # Helper method to reorder all waiting positions to be consecutive starting from 1
    sub _reorder_waiting_positions ($class, $db, $session_id) {
        $db = $db->db if $db isa Registry::DAO;
        
        # Use a two-step approach to avoid constraint violations
        # Step 1: Move all waiting entries to negative positions temporarily
        my $sql1 = q{
            UPDATE waitlist 
            SET position = -position - 1000
            WHERE session_id = ? 
            AND status = 'waiting'
        };
        
        $db->query($sql1, $session_id);
        
        # Step 2: Reorder all waiting entries to have consecutive positions starting from 1
        my $sql2 = q{
            UPDATE waitlist 
            SET position = subquery.new_position
            FROM (
                SELECT id, 
                       ROW_NUMBER() OVER (ORDER BY -position) as new_position
                FROM waitlist
                WHERE session_id = ? 
                AND status = 'waiting'
                AND position < 0
            ) subquery
            WHERE waitlist.id = subquery.id
        };
        
        $db->query($sql2, $session_id);
    }
}