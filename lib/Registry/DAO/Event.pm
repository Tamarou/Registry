use v5.40.0;
use utf8;
use experimental qw(try);
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

    use constant table => 'sessions';

    sub create ( $class, $db, $data ) {
        $data->{slug} //= lc( $data->{name} =~ s/\s+/-/gr )
          if defined $data->{name};
        $data->{status} //= 'draft';
        $class->SUPER::create( $db, $data );
    }

    method events ($db) {

        # TODO: this should be a join
        $db->select( 'session_events', '*', { session_id => $id } )
          ->hashes->map(
            sub { Registry::DAO::Event->find( $db, { id => $_->{event_id} } ) }
        )->to_array->@*;
    }

    method add_events ( $db, @events ) {
        my $data = [ map { { session_id => $id, event_id => $_ } } @events ];
        $db->insert( 'session_events', $_ ) for $data->@*;
        return $self;
    }

    # Get teachers for this session
    method teachers($db) {

        # TODO: this should be a join
        $db->select( 'session_teachers', '*', { session_id => $id } )
          ->hashes->map(
            sub { Registry::DAO::User->find( $db, { id => $_->{teacher_id} } ) }
        )->to_array->@*;
    }

    # Add teachers to this session
    method add_teachers( $db, @teacher_ids ) {
        my $data =
          [ map { { session_id => $id, teacher_id => $_ } } @teacher_ids ];
        $db->insert( 'session_teachers', $_ ) for $data->@*;
        return $self;
    }

    # Remove a teacher from this session
    method remove_teacher( $db, $teacher_id ) {
        $db->delete(
            'session_teachers',
            {
                session_id => $id,
                teacher_id => $teacher_id
            }
        );
        return $self;
    }

    # Get pricing for this session
    method pricing($db) {
        Registry::DAO::Pricing->find( $db, { session_id => $id } );
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
}

class Registry::DAO::Event :isa(Registry::DAO::Object) {
    use Carp         qw( carp );
    use experimental qw(try);

    field $id :param :reader;
    field $location_id :param;
    field $project_id :param;
    field $teacher_id :param;
    field $min_age :param :reader;
    field $max_age :param :reader;
    field $capacity :param :reader;
    # TODO: Event class needs:
    # - Remove //= {} default
    # - Add BUILD for JSON decoding
    # - Use { -json => $metadata } in create/update
    # - Add explicit metadata() accessor
    field $metadata :param :reader //= {};
    field $notes :param :reader    //= '';
    field $created_at :param :reader;
    field $updated_at :param :reader;

    use constant table => 'events';

    sub create ( $class, $db, $data ) {
        $class->SUPER::create( $db, $data );
    }

    method location ($db) {
        Registry::DAO::Location->find( $db, { id => $location_id } );
    }

    method teacher ($db) {
        Registry::DAO::User->find( $db, { id => $teacher_id } );
    }

    method project ($db) {
        Registry::DAO::Project->find( $db, { id => $project_id } );
    }

    # Get sessions this event belongs to
    method sessions($db) {

        # TODO optimize this with a join
        $db->select( 'session_events', '*', { event_id => $id } )->hashes->map(
            sub {
                Registry::DAO::Session->find( $db, { id => $_->{session_id} } );
            }
        )->to_array->@*;
    }

    # Helper method to check if event is age-appropriate for a student
    method is_age_appropriate($age) {
        return 1 unless defined $min_age || defined $max_age;
        return 0 if defined $min_age && $age < $min_age;
        return 0 if defined $max_age && $age > $max_age;
        return 1;
    }

    # Helper method to check if event is at capacity
    method is_at_capacity {
        return 0 unless defined $capacity && $capacity > 0;

        # In a real implementation, we'd count enrollments
        # This is a stub for demonstration
        my $current_enrollment = 0;    # Replace with actual count
        return $current_enrollment >= $capacity;
    }

    # Helper method to get available capacity
    method available_capacity {
        return undef unless defined $capacity;

        # In a real implementation, we'd count enrollments
        # This is a stub for demonstration
        my $current_enrollment = 0;    # Replace with actual count
        return $capacity - $current_enrollment;
    }
}

class Registry::DAO::Enrollment :isa(Registry::DAO::Object) {
    field $id :param :reader;
    field $session_id :param :reader;
    field $student_id :param :reader;
    field $status :param :reader   //= 'pending';
    # TODO: Enrollment class needs:
    # - Remove //= {} default
    # - Add BUILD for JSON decoding
    # - Use { -json => $metadata } in create/update
    # - Add explicit metadata() accessor
    field $metadata :param :reader //= {};
    field $created_at :param :reader;
    field $updated_at :param :reader;

    use constant table => 'enrollments';

    sub create ( $class, $db, $data ) {
        $data->{status} //= 'pending';
        $class->SUPER::create( $db, $data );
    }

    # Get the session this enrollment belongs to
    method session($db) {
        Registry::DAO::Session->find( $db, { id => $session_id } );
    }

    # Get the student associated with this enrollment
    method student($db) {
        Registry::DAO::User->find( $db, { id => $student_id } );
    }

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

}

class Registry::DAO::SessionTeacher :isa(Registry::DAO::Object) {
    field $id :param :reader;
    field $session_id :param;
    field $teacher_id :param;
    field $created_at :param :reader;
    field $updated_at :param :reader;

    use constant table => 'session_teachers';

    # Get the session this teacher assignment belongs to
    method session($db) {
        Registry::DAO::Session->find( $db, { id => $session_id } );
    }

    # Get the teacher assigned to the session
    method teacher($db) {
        Registry::DAO::User->find( $db, { id => $teacher_id } );
    }
}

class Registry::DAO::Pricing :isa(Registry::DAO::Object) {
    field $id :param :reader;
    field $session_id :param;
    field $amount :param :reader;
    field $currency :param :reader //= 'USD';
    field $early_bird_amount :param :reader;
    field $early_bird_cutoff_date :param :reader;
    field $sibling_discount :param :reader;
    # TODO: Pricing class needs:
    # - Remove //= {} default
    # - Add BUILD for JSON decoding
    # - Use { -json => $metadata } in create/update
    # - Add explicit metadata() accessor
    field $metadata :param :reader //= {};
    field $created_at :param :reader;
    field $updated_at :param :reader;

    use constant table => 'pricing';

    # Get the session this pricing belongs to
    method session($db) {
        Registry::DAO::Session->find( $db, { id => $session_id } );
    }

    # Helper method to check if early bird pricing is available
    method is_early_bird_available {
        return 0 unless $early_bird_amount && $early_bird_cutoff_date;

        # In a real implementation, we'd compare against current date
        # This is a simplified version
        my $today = time;    # or use DateTime
        return $today <= $early_bird_cutoff_date;
    }

    # Helper method to calculate effective price (early bird if applicable)
    method effective_price {
        if ( $self->is_early_bird_available ) {
            return $early_bird_amount;
        }
        return $amount;
    }

    # Helper method to calculate sibling discounted price
    method sibling_price {
        return $amount unless $sibling_discount;
        return $amount * ( 1 - ( $sibling_discount / 100 ) );
    }

    # Helper method to format price with currency
    method formatted_price {
        my $price = $self->effective_price;
        if ( $currency eq 'USD' ) {
            return sprintf( '$%.2f', $price );
        }
        return sprintf( '%.2f %s', $price, $currency );
    }
}