use 5.40.2;
use Object::Pad;

class Registry::DAO::Session :isa(Registry::DAO::Object) {
    use Carp         qw( carp );
    use experimental qw(try);
    use Mojo::JSON   qw( decode_json );
    use Scalar::Util qw( blessed );

    field $id :param :reader;
    field $name :param :reader;
    field $slug :param :reader;
    field $metadata :param :reader = {};
    field $notes :param :reader = '';
    field $created_at :param :reader;
    field $updated_at :param :reader;
    field $session_type :param :reader = 'regular';
    field $start_date :param :reader;
    field $end_date :param :reader;
    field $status :param :reader = 'draft';
    field $capacity :param :reader;

    sub table { 'sessions' }
    
    ADJUST {
        # Decode JSON metadata if it's a string
        if (defined $metadata && !ref $metadata) {
            try {
                $metadata = decode_json($metadata);
            }
            catch ($e) {
                carp "Failed to decode session metadata: $e";
                $metadata = {};
            }
        }
    }

    sub create ( $class, $db, $data ) {
        $data->{slug} //= lc( $data->{name} =~ s/\s+/-/gr )
          if defined $data->{name};
        
        # Store project_id in metadata if provided
        if (exists $data->{project_id}) {
            $data->{metadata} //= {};
            $data->{metadata}{project_id} = delete $data->{project_id};
        }
        
        # Handle pricing in metadata if provided
        if (exists $data->{pricing}) {
            $data->{metadata} //= {};
            $data->{metadata}{pricing} = delete $data->{pricing};
        }
        
        # Handle location_id in metadata if provided
        if (exists $data->{location_id}) {
            $data->{metadata} //= {};
            $data->{metadata}{location_id} = delete $data->{location_id};
        }
        
        # Convert timestamps to dates for start_date and end_date
        for my $field (qw(start_date end_date)) {
            if (exists $data->{$field} && $data->{$field} =~ /^\d+$/) {
                # Convert unix timestamp to date string
                my ($sec, $min, $hour, $mday, $mon, $year) = localtime($data->{$field});
                $data->{$field} = sprintf('%04d-%02d-%02d', $year + 1900, $mon + 1, $mday);
            }
        }
        
        # Handle JSON field encoding
        if (exists $data->{metadata} && ref $data->{metadata} eq 'HASH') {
            $data->{metadata} = { -json => $data->{metadata} };
        }
        
        $class->SUPER::create( $db, $data );
    }

    method events ($db) {
        $db = $db->db if $db isa Registry::DAO;

        # TODO: this should be a join
        my @events = $db->select( 'session_events', '*', { session_id => $id } )
          ->hashes->map(
            sub { 
                my $event = Registry::DAO::Event->find( $db, { id => $_->{event_id} } );
                return $event if blessed($event);
                return; # Skip if event not found
            }
        )->grep(sub { defined $_ })->each;
        return wantarray ? @events : \@events;
    }

    method add_events ( $db, @events ) {
        $db = $db->db if $db isa Registry::DAO;
        my $data = [ map { { session_id => $id, event_id => $_ } } @events ];
        $db->insert( 'session_events', $_ ) for $data->@*;
        return $self;
    }

    # Get teachers for this session
    method teachers($db) {
        $db = $db->db if $db isa Registry::DAO;

        # TODO: this should be a join
        $db->select( 'session_teachers', '*', { session_id => $id } )
          ->hashes->map(
            sub { Registry::DAO::User->find( $db, { id => $_->{teacher_id} } ) }
        )->to_array->@*;
    }

    # Add teachers to this session
    method add_teachers( $db, @teacher_ids ) {
        $db = $db->db if $db isa Registry::DAO;
        my $data =
          [ map { { session_id => $id, teacher_id => $_ } } @teacher_ids ];
        $db->insert( 'session_teachers', $_ ) for $data->@*;
        return $self;
    }

    # Remove a teacher from this session
    method remove_teacher( $db, $teacher_id ) {
        $db = $db->db if $db isa Registry::DAO;
        $db->delete(
            'session_teachers',
            {
                session_id => $id,
                teacher_id => $teacher_id
            }
        );
        return $self;
    }

    # Get pricing plans for this session
    method pricing_plans($db) {
        require Registry::DAO::PricingPlan;
        Registry::DAO::PricingPlan->get_pricing_plans( $db, $id );
    }
    
    # Get best price for this session given context
    method get_best_price($db, $context = {}) {
        require Registry::DAO::PricingPlan;
        Registry::DAO::PricingPlan->get_best_price( $db, $id, $context );
    }

    # Get enrollments for this session
    method enrollments($db) {
        Registry::DAO::Enrollment->find( $db, { session_id => $id } );
    }

    # Note: Status and date information is now stored in metadata if needed
    # These can be accessed via $self->metadata->{status}, $self->metadata->{start_date}, etc.

    # Note: Capacity calculations now depend on metadata or event data
    # These methods would need to be reimplemented based on current schema
    
    # Get waitlist for this session
    method waitlist($db) {
        require Registry::DAO::Waitlist;
        Registry::DAO::Waitlist->get_session_waitlist($db, $id);
    }
    
    # Get waitlist count
    method waitlist_count($db) {
        require Registry::DAO::Waitlist;
        my $waitlist = Registry::DAO::Waitlist->get_session_waitlist($db, $id, 'waiting');
        return scalar @$waitlist;
    }
    
    # Status management methods
    method publish($db) {
        $db = $db->db if $db isa Registry::DAO;
        my $updated = $self->update($db, { status => 'published' });
        # Update the local field to reflect the change
        $status = 'published' if $updated;
        return $updated;
    }
    
    method is_published() {
        return $status eq 'published';
    }
    
    method is_draft() {
        return $status eq 'draft';
    }
    
    method close($db) {
        $db = $db->db if $db isa Registry::DAO;
        my $updated = $self->update($db, { status => 'closed' });
        # Update the local field to reflect the change
        $status = 'closed' if $updated;
        return $updated;
    }
    
    method is_closed() {
        return $status eq 'closed';
    }

    method has_started() {
        return 0 unless defined $start_date;

        # Get current date in YYYY-MM-DD format
        my ($year, $month, $day) = (localtime)[5, 4, 3];
        $year += 1900;
        $month += 1;
        my $today = sprintf('%04d-%02d-%02d', $year, $month, $day);

        # Compare date strings (YYYY-MM-DD format allows lexical comparison)
        return $start_date le $today;
    }
}