use 5.40.2;
use utf8;
use experimental qw(try);
use Object::Pad;

class Registry::DAO::ProgramType :isa(Registry::DAO::Object) {
    use Carp qw( croak );
    use Mojo::JSON qw( decode_json encode_json );
    
    field $id :param :reader;
    field $slug :param :reader;
    field $name :param :reader;
    field $config :param :reader = {};
    field $created_at :param :reader;
    field $updated_at :param :reader;
    
    use constant table => 'program_types';
    
    BUILD {
        # Decode JSON config if it's a string
        if (defined $config && !ref $config) {
            try {
                $config = decode_json($config);
            }
            catch ($e) {
                croak "Failed to decode program type config: $e";
            }
        }
    }
    
    sub create ($class, $db, $data) {
        # Ensure slug is generated from name if not provided
        $data->{slug} //= lc($data->{name} =~ s/\s+/-/gr)
            if defined $data->{name};
        
        # Encode config as JSON if it's a hashref
        if (exists $data->{config} && ref $data->{config} eq 'HASH') {
            $data->{config} = { -json => $data->{config} };
        }
        
        $class->SUPER::create($db, $data);
    }
    
    method update ($db, $data) {
        # Encode config as JSON if it's a hashref
        if (exists $data->{config} && ref $data->{config} eq 'HASH') {
            $data->{config} = { -json => $data->{config} };
        }
        
        $self->SUPER::update($db, $data);
    }
    
    
    # Helper methods to access config properties
    method enrollment_rules {
        return $config->{enrollment_rules} // {};
    }
    
    method standard_times {
        return $config->{standard_times} // {};
    }
    
    method session_pattern {
        return $config->{session_pattern} // '';
    }
    
    # Check if siblings must be in same session
    method same_session_for_siblings {
        return $self->enrollment_rules->{same_session_for_siblings} // 0;
    }
    
    # Get standard time for a specific day
    method standard_time_for_day ($day) {
        return $self->standard_times->{lc($day)};
    }
    
    # List all program types
    sub list ($class, $db) {
        my $results = $db->select(
            $class->table,
            '*',
            {},
            { order_by => 'name' }
        )->hashes;
        
        return [
            map { $class->new(%$_) } @$results
        ];
    }
    
    # Find by slug
    sub find_by_slug ($class, $db, $slug) {
        my $row = $db->select($class->table, undef, { slug => $slug })->hash;
        return unless $row;
        return $class->new(%$row);
    }
}