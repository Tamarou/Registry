use 5.40.2;
use Object::Pad;

class Registry::DAO::Location :isa(Registry::DAO::Object) {
    use Mojo::JSON qw(decode_json encode_json);

    field $id :param :reader = undef;
    field $name :param :reader = undef;
    field $slug :param :reader = undef;
    field $address_info :param :reader = {};
    field $metadata :param :reader = {};
    field $notes :param :reader = undef;
    field $capacity :param :reader = undef;
    field $contact_info :param :reader = {};
    field $facilities :param :reader = {};
    field $latitude :param :reader = undef;
    field $longitude :param :reader = undef;
    field $created_at :param :reader = undef;
    field $updated_at :param :reader = undef;

    sub table { 'locations' }

    sub create ( $class, $db, $data ) {
        for my $field (qw(address_info metadata contact_info facilities)) {
            next unless exists $data->{$field};
            if (ref $data->{$field} eq 'HASH' || ref $data->{$field} eq 'ARRAY') {
                $data->{$field} = { -json => $data->{$field} };
            }
        }
        $data->{slug} //= lc( $data->{name} =~ s/\s+/_/gr );
        $class->SUPER::create( $db, $data );
    }

    sub validate_address( $class, $addr ) {
        return {} unless $addr;

        my $normalized = ref $addr ? $addr : decode_json($addr);

        die "address_info must be a hashref"
          unless ref $normalized eq 'HASH';

        if ( my $coords = $normalized->{coordinates} ) {
            die "Invalid coordinates structure"
              unless ref $coords eq 'HASH'
              && exists $coords->{lat}
              && exists $coords->{lng};

            die "Invalid latitude"
              unless $coords->{lat} >= -90
              && $coords->{lat} <= 90;

            die "Invalid longitude"
              unless $coords->{lng} >= -180
              && $coords->{lng} <= 180;
        }

        return $normalized;
    }

    method get_formatted_address() {
        return "" unless %$address_info;

        return join(
            "\n",
            $address_info->{street_address} // (),
            ( $address_info->{unit} ? "Unit " . $address_info->{unit} : () ),
            join( ", ",
                grep { defined && length } $address_info->{city},
                $address_info->{state},
                $address_info->{postal_code} ),
            ( $address_info->{country} || "USA" )
        );
    }

    method has_coordinates() {
        my $coords = $address_info->{coordinates};
        return $coords && exists $coords->{lat} && exists $coords->{lng};
    }

    method get_coordinates() {
        return unless $self->has_coordinates;
        return @{ $address_info->{coordinates} }{qw(lat lng)};
    }

    method address() {
        return $address_info;
    }

    # Legacy field access methods for backward compatibility
    method address_street() {
        return $address_info->{street_address};
    }

    method address_city() {
        return $address_info->{city};
    }

    method address_state() {
        return $address_info->{state};
    }

    method address_zip() {
        return $address_info->{postal_code};
    }

    method description() {
        return $notes;
    }

    method save($db, $data = {}) {
        $db = $db->db if $db isa Registry::DAO;
        # If this has an ID, update; otherwise create
        if ($id) {
            return $self->update($db, $data);
        } else {
            # For new objects, merge instance data with passed data
            my %instance_data = (
                name => $name,
                slug => $slug,
                address_info => $address_info,
                metadata => $metadata,
                notes => $notes,
            );
            # Remove undefined values
            my %clean_data = map { defined $instance_data{$_} ? ($_ => $instance_data{$_}) : () } keys %instance_data;
            return Registry::DAO::Location->create($db, { %clean_data, %$data });
        }
    }
    
    # Find active sessions at this location with optional filters
    method find_active_sessions($db, $filters = {}) {
        $db = $db->db if $db isa Registry::DAO;
        
        # Build SQL with filters
        my @where_clauses = (
            'e.location_id = ?',
            "s.status = 'published'"
            # Note: Temporarily re-disable end date filter to debug
            # '(s.end_date IS NULL OR s.end_date >= CURRENT_DATE)'
        );
        my @params = ($id);
        
        # Add age filters
        if ($filters->{min_age}) {
            push @where_clauses, '(e.max_age IS NULL OR e.max_age >= ?)';
            push @params, $filters->{min_age};
        }
        if ($filters->{max_age}) {
            push @where_clauses, '(e.min_age IS NULL OR e.min_age <= ?)';
            push @params, $filters->{max_age};
        }
        
        # Add start date filter
        if ($filters->{start_date}) {
            push @where_clauses, 's.start_date >= ?';
            push @params, $filters->{start_date};
        }
        
        # Add program type filter
        if ($filters->{program_type}) {
            push @where_clauses, 'p.slug = ?';
            push @params, $filters->{program_type};
        }
        
        my $where = join(' AND ', @where_clauses);
        
        my $sql = qq{
            SELECT DISTINCT s.*, p.slug as program_type_slug
            FROM sessions s
            JOIN session_events se ON se.session_id = s.id
            JOIN events e ON e.id = se.event_id
            JOIN projects proj ON proj.id = e.project_id
            LEFT JOIN program_types p ON p.slug = proj.program_type_slug
            WHERE $where
            ORDER BY s.start_date
        };
        
        my @results = $db->query($sql, @params)->hashes->each;
        return [] unless @results;
        return [ map { Registry::DAO::Session->new(%$_) } @results ];
    }
}