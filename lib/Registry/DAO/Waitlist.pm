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
    
    BUILD {
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
        my $entry = $class->find($db, {
            session_id => $session_id,
            student_id => $student_id,
            status => 'waiting'
        });
        
        return $entry ? $entry->position : undef;
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
        my $is_expired = $db->query('SELECT ? < NOW()', $expires_at)->array->[0];
        croak "Offer has expired" if $expires_at && $is_expired;
        
        # Start transaction
        my $tx = $db->begin;
        
        try {
            # Create enrollment
            require Registry::DAO::Event;
            Registry::DAO::Enrollment->create($db, {
                session_id => $session_id,
                student_id => $student_id,
                status => 'pending',
                metadata => { from_waitlist => 1 }
            });
            
            # Update waitlist status
            $self->update($db, { status => 'declined' }); # Use 'declined' to keep history
            
            $tx->commit;
        }
        catch ($e) {
            $tx->rollback;
            croak "Failed to accept waitlist offer: $e";
        }
        
        return $self;
    }
    
    # Decline waitlist offer
    method decline_offer ($db) {
        croak "Can only decline offers with status 'offered'" unless $status eq 'offered';
        
        $self->update($db, { status => 'declined' });
        
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
}