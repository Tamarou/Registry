use 5.40.2;
use Object::Pad;

class Registry::DAO::Session :isa(Registry::DAO::Object) {
    use Carp         qw( carp );
    use experimental qw(try);

    field $id :param :reader;
    field $name :param :reader;
    field $slug :param :reader;
    field $metadata :param :reader = {};
    field $notes :param :reader = '';
    field $created_at :param :reader;
    field $updated_at :param :reader;

    sub table { 'sessions' }

    sub create ( $class, $db, $data ) {
        $data->{slug} //= lc( $data->{name} =~ s/\s+/-/gr )
          if defined $data->{name};
        
        # Handle JSON field encoding
        if (exists $data->{metadata} && ref $data->{metadata}) {
            $data->{metadata} = { -json => $data->{metadata} };
        }
        
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
}