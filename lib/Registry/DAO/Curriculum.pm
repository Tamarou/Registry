use 5.40.2;
use Object::Pad;

# ABOUTME: DAO for managing educational curriculum in the system
# ABOUTME: Handles curriculum content, lessons, standards alignment, and sharing

class Registry::DAO::Curriculum :isa(Registry::DAO::Object) {
    use Carp         qw( carp );
    use experimental qw(try);
    use Mojo::JSON   qw( decode_json encode_json );
    use Scalar::Util qw( blessed );

    field $id :param :reader;
    field $name :param :reader;
    field $slug :param :reader;
    field $description :param :reader = '';
    field $metadata :param :reader = {};
    field $notes :param :reader = '';
    field $created_at :param :reader;
    field $updated_at :param :reader;

    sub table { 'curriculum' }

    ADJUST {
        # Decode JSON metadata if it's a string
        if (defined $metadata && !ref $metadata) {
            try {
                $metadata = decode_json($metadata);
            }
            catch ($e) {
                carp "Failed to decode curriculum metadata: $e";
                $metadata = {};
            }
        }
    }

    sub create ( $class, $db, $data ) {
        $data->{slug} //= lc( $data->{name} =~ s/\s+/-/gr )
          if defined $data->{name};

        # Store additional fields in metadata
        for my $field (qw(subject grade_level duration materials)) {
            if (exists $data->{$field}) {
                $data->{metadata} //= {};
                $data->{metadata}{$field} = delete $data->{$field};
            }
        }

        # Handle JSON field encoding
        if (exists $data->{metadata} && ref $data->{metadata} eq 'HASH') {
            $data->{metadata} = { -json => $data->{metadata} };
        }

        $class->SUPER::create( $db, $data );
    }

    # Get lessons for this curriculum
    method lessons($db) {
        return $metadata->{lessons} // [];
    }

    # Add a lesson to the curriculum
    method add_lesson($db, $lesson_data) {
        $db = $db->db if $db isa Registry::DAO;

        $metadata->{lessons} //= [];
        push @{$metadata->{lessons}}, {
            id => $db->query('SELECT gen_random_uuid() as id')->hash->{id},
            created_at => time,
            %$lesson_data
        };

        # Sort lessons by week number if specified
        if (exists $lesson_data->{week}) {
            $metadata->{lessons} = [
                sort { ($a->{week} // 0) <=> ($b->{week} // 0) }
                @{$metadata->{lessons}}
            ];
        }

        $self->update($db, {
            metadata => { -json => $metadata }
        });

        return $self;
    }

    # Get educational standards linked to this curriculum
    method standards($db) {
        return $metadata->{standards} // [];
    }

    # Link educational standard to curriculum
    method add_standard($db, $standard_data) {
        $db = $db->db if $db isa Registry::DAO;

        $metadata->{standards} //= [];
        push @{$metadata->{standards}}, {
            id => $db->query('SELECT gen_random_uuid() as id')->hash->{id},
            created_at => time,
            %$standard_data
        };

        $self->update($db, {
            metadata => { -json => $metadata }
        });

        return $self;
    }

    # Get sharing settings
    method shared_with($db) {
        $db = $db->db if $db isa Registry::DAO;

        # Check if curriculum_shares table exists
        my $result = $db->query(q{
            SELECT EXISTS (
                SELECT 1 FROM information_schema.tables
                WHERE table_name = 'curriculum_shares'
            )
        });

        return [] unless $result->hash->{exists};

        return $db->select('curriculum_shares', '*', {
            curriculum_id => $id
        })->hashes->to_array;
    }

    # Share curriculum with a teacher
    method share_with($db, $user_id, $permission = 'view_only') {
        $db = $db->db if $db isa Registry::DAO;

        # Ensure curriculum_shares table exists
        $db->query(q{
            CREATE TABLE IF NOT EXISTS curriculum_shares (
                id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
                curriculum_id uuid NOT NULL REFERENCES curriculum(id),
                user_id uuid REFERENCES users(id),
                program_id uuid REFERENCES programs(id),
                permission text DEFAULT 'view_only',
                created_at timestamp with time zone DEFAULT now(),
                UNIQUE(curriculum_id, user_id)
            )
        });

        $db->insert('curriculum_shares', {
            curriculum_id => $id,
            user_id       => $user_id,
            permission    => $permission
        });

        return $self;
    }

    # Share curriculum with all teachers in a program
    method share_with_program($db, $program_id, $permission = 'view_only') {
        $db = $db->db if $db isa Registry::DAO;

        # Ensure curriculum_shares table exists
        $db->query(q{
            CREATE TABLE IF NOT EXISTS curriculum_shares (
                id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
                curriculum_id uuid NOT NULL REFERENCES curriculum(id),
                user_id uuid REFERENCES users(id),
                program_id uuid REFERENCES programs(id),
                permission text DEFAULT 'view_only',
                created_at timestamp with time zone DEFAULT now()
            )
        });

        $db->insert('curriculum_shares', {
            curriculum_id => $id,
            program_id    => $program_id,
            permission    => $permission
        });

        return $self;
    }

    # Version management
    method versions($db) {
        return $metadata->{versions} // [];
    }

    # Create a new version
    method create_version($db, $version_data) {
        $db = $db->db if $db isa Registry::DAO;

        $metadata->{versions} //= [];
        push @{$metadata->{versions}}, {
            id => $db->query('SELECT gen_random_uuid() as id')->hash->{id},
            created_at => time,
            %$version_data
        };

        $self->update($db, {
            metadata => { -json => $metadata }
        });

        return $self;
    }

    # Resource management
    method resources($db) {
        return $metadata->{resources} // [];
    }

    # Add a resource
    method add_resource($db, $resource_data) {
        $db = $db->db if $db isa Registry::DAO;

        $metadata->{resources} //= [];
        push @{$metadata->{resources}}, {
            id => $db->query('SELECT gen_random_uuid() as id')->hash->{id},
            created_at => time,
            %$resource_data
        };

        $self->update($db, {
            metadata => { -json => $metadata }
        });

        return $self;
    }

    # Get events using this curriculum
    method events($db) {
        $db = $db->db if $db isa Registry::DAO;

        $db->select('event_curriculum', '*', {
            curriculum_id => $id
        })->hashes->map(
            sub { Registry::DAO::Event->find( $db, { id => $_->{event_id} } ) }
        )->to_array->@*;
    }
}