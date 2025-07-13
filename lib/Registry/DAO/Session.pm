use 5.40.2;
use Object::Pad;

class Registry::DAO::Session :isa(Registry::DAO::Object) {
    use Carp         qw( carp );
    use experimental qw(try);

    field $id :param :reader;
    field $name :param :reader;
    field $slug :param :reader;
    field $start_date :param :reader;
    field $end_date :param :reader;
    field $status :param :reader   //= 'draft';
    # TODO: Session class needs:
    # - Remove //= {} default
    # - Add BUILD for JSON decoding
    # - Handle { -json => $metadata } in create/update
    # - Add explicit metadata() accessor
    field $metadata :param :reader //= {};
    field $notes :param :reader    //= '';
    field $created_at :param :reader = time;
    field $updated_at :param :reader;

    sub table { 'sessions' }

    sub create ( $class, $db, $data ) {
        $data->{slug} //= lc( $data->{name} =~ s/\s+/-/gr )
          if defined $data->{name};
        $data->{status} //= 'draft';
        $class->SUPER::create( $db, $data );
    }

    method events ($db) {
        $db = $db->db if $db isa Registry::DAO;

        # TODO: this should be a join
        $db->select( 'session_events', '*', { session_id => $id } )
          ->hashes->map(
            sub { Registry::DAO::Event->find( $db, { id => $_->{event_id} } ) }
        )->to_array->@*;
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

    # Helper method for duration days
    method duration_days {
        return undef unless $start_date && $end_date;

   # In a real implementation, we'd parse the dates and calculate the difference
        return ( $end_date - $start_date ) +
          1;    # Include both start and end dates
    }

    my $update_status = method( $db, $new_status ) {
        $status = $new_status;
        return $self->update( $db, { status => $status } );
    };

    # Helper method for publication status
    method publish($db) { $self->$update_status( $db, 'published' ) }
    method close($db)   { $self->$update_status( $db, 'closed' ) }

    method is_published { $status eq 'published' }
    method is_closed    { $status eq 'closed' }

    method total_capacity($db) {
        return max( map { $_->total_capacity } $self->events($db) );
    }

    # Helper method to check if session is at capacity
    method is_at_capacity($db) {
        return 0 unless $self->available_capacity($db);
    }

    # Helper method to get available capacity
    method available_capacity($db) {
        return $self->total_capacity - $self->enrollments($db)->count;
    }
    
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
}