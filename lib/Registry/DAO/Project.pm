use 5.40.2;
use Object::Pad;

class Registry::DAO::Project :isa(Registry::DAO::Object) {
    use Mojo::JSON qw(decode_json encode_json);
    use Carp qw(croak);
    use experimental qw(try);

    field $id :param :reader;
    field $name :param :reader;
    field $slug :param :reader;
    field $program_type_slug :param :reader;
    field $metadata :param :reader = {};
    field $notes :param :reader = '';
    field $created_at :param :reader;
    field $updated_at :param :reader;

    sub table { 'projects' }

    ADJUST {
        # Decode JSON metadata if it's a string
        if (defined $metadata && !ref $metadata) {
            try {
                $metadata = decode_json($metadata);
            }
            catch ($e) {
                croak "Failed to decode project metadata: $e";
            }
        }
    }

    sub create ( $class, $db, $data ) {
        $data->{slug} //= lc( $data->{name} =~ s/\s+/_/gr );
        
        # Encode metadata as JSON if it's a hashref
        if (exists $data->{metadata} && ref $data->{metadata} eq 'HASH') {
            $data->{metadata} = { -json => $data->{metadata} };
        }
        
        $class->SUPER::create( $db, $data );
    }

    method update ($db, $data) {
        # Encode metadata as JSON if it's a hashref
        if (exists $data->{metadata} && ref $data->{metadata} eq 'HASH') {
            $data->{metadata} = { -json => $data->{metadata} };
        }
        
        $self->SUPER::update($db, $data);
    }

    # Get program overview with enrollment and capacity data for admin dashboard
    sub get_program_overview($class, $db, $time_range) {
        my $sql = q{
            SELECT
                p.id as program_id,
                p.name as program_name,
                p.status as program_status,
                COUNT(DISTINCT s.id) as session_count,
                COUNT(DISTINCT e.id) as total_enrollments,
                COUNT(DISTINCT CASE WHEN e.status = 'active' THEN e.id END) as active_enrollments,
                COUNT(DISTINCT w.id) as waitlist_count,
                SUM(ev.capacity) as total_capacity,
                MIN(s.start_date) as earliest_start,
                MAX(s.end_date) as latest_end
            FROM projects p
            LEFT JOIN sessions s ON p.id = s.project_id
            LEFT JOIN enrollments e ON s.id = e.session_id
            LEFT JOIN waitlist w ON s.id = w.session_id AND w.status IN ('waiting', 'offered')
            LEFT JOIN events ev ON s.id = ev.session_id
        };

        my @where_conditions;
        my @params;

        if ($time_range eq 'current') {
            push @where_conditions, 's.start_date <= ? AND s.end_date >= ?';
            my $now = time();
            push @params, $now, $now;
        } elsif ($time_range eq 'upcoming') {
            push @where_conditions, 's.start_date > ?';
            push @params, time();
        }

        if (@where_conditions) {
            $sql .= ' WHERE ' . join(' AND ', @where_conditions);
        }

        $sql .= q{
            GROUP BY p.id, p.name, p.status
            ORDER BY p.name
        };

        my $results = $db->query($sql, @params)->hashes->to_array;

        # Calculate utilization rates
        for my $program (@$results) {
            if ($program->{total_capacity} && $program->{total_capacity} > 0) {
                $program->{utilization_rate} = sprintf("%.0f",
                    ($program->{active_enrollments} / $program->{total_capacity}) * 100
                );
            } else {
                $program->{utilization_rate} = 0;
            }
        }

        return $results;
    }

}