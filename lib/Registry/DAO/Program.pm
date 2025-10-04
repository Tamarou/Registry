use 5.40.2;
use Object::Pad;

# ABOUTME: DAO for managing educational programs in the system
# ABOUTME: Handles program CRUD operations, teacher assignments, and scheduling

class Registry::DAO::Program :isa(Registry::DAO::Object) {
    use Carp         qw( carp );
    use experimental qw(try);
    use Mojo::JSON   qw( decode_json encode_json );
    use Scalar::Util qw( blessed );

    field $id :param :reader;
    field $name :param :reader;
    field $slug :param :reader;
    field $metadata :param :reader = {};
    field $notes :param :reader = '';
    field $created_at :param :reader;
    field $updated_at :param :reader;

    sub table { 'programs' }

    ADJUST {
        # Decode JSON metadata if it's a string
        if (defined $metadata && !ref $metadata) {
            try {
                $metadata = decode_json($metadata);
            }
            catch ($e) {
                carp "Failed to decode program metadata: $e";
                $metadata = {};
            }
        }
    }

    sub create ( $class, $db, $data ) {
        $data->{slug} //= lc( $data->{name} =~ s/\s+/-/gr )
          if defined $data->{name};

        # Handle JSON field encoding
        if (exists $data->{metadata} && ref $data->{metadata} eq 'HASH') {
            $data->{metadata} = { -json => $data->{metadata} };
        }

        $class->SUPER::create( $db, $data );
    }

    # Get sessions for this program
    method sessions($db) {
        $db = $db->db if $db isa Registry::DAO;

        require Registry::DAO::Session;
        Registry::DAO::Session->find( $db, {
            'metadata->program_id' => $id
        });
    }

    # Get teachers assigned to this program
    method teachers($db) {
        $db = $db->db if $db isa Registry::DAO;

        # Check if program_teachers table exists
        my $result = $db->query(q{
            SELECT EXISTS (
                SELECT 1 FROM information_schema.tables
                WHERE table_name = 'program_teachers'
            )
        });

        return [] unless $result->hash->{exists};

        $db->select( 'program_teachers', '*', { program_id => $id } )
          ->hashes->map(
            sub { Registry::DAO::User->find( $db, { id => $_->{teacher_id} } ) }
        )->to_array->@*;
    }

    # Add teachers to this program
    method add_teachers( $db, @teacher_ids ) {
        $db = $db->db if $db isa Registry::DAO;

        # Ensure program_teachers table exists
        $db->query(q{
            CREATE TABLE IF NOT EXISTS program_teachers (
                id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
                program_id uuid NOT NULL REFERENCES programs(id),
                teacher_id uuid NOT NULL REFERENCES users(id),
                role text DEFAULT 'instructor',
                created_at timestamp with time zone DEFAULT now(),
                UNIQUE(program_id, teacher_id)
            )
        });

        my $data = [ map { {
            program_id => $id,
            teacher_id => $_
        } } @teacher_ids ];

        $db->insert( 'program_teachers', $_ ) for $data->@*;
        return $self;
    }

    # Remove a teacher from this program
    method remove_teacher( $db, $teacher_id ) {
        $db = $db->db if $db isa Registry::DAO;
        $db->delete(
            'program_teachers',
            {
                program_id => $id,
                teacher_id => $teacher_id
            }
        );
        return $self;
    }

    # Get curriculum for this program
    method curriculum($db) {
        $db = $db->db if $db isa Registry::DAO;

        # Check if program_curriculum relationship exists
        return $metadata->{curriculum_id}
            ? Registry::DAO::Curriculum->find( $db, { id => $metadata->{curriculum_id} } )
            : undef;
    }

    # Set curriculum for this program
    method set_curriculum($db, $curriculum_id) {
        $db = $db->db if $db isa Registry::DAO;

        $metadata->{curriculum_id} = $curriculum_id;
        $self->update($db, {
            metadata => { -json => $metadata }
        });
        return $self;
    }

    # Get schedule for this program
    method schedule($db) {
        return $metadata->{schedule} // {};
    }

    # Set schedule for this program
    method set_schedule($db, $schedule_data) {
        $db = $db->db if $db isa Registry::DAO;

        $metadata->{schedule} = $schedule_data;
        $self->update($db, {
            metadata => { -json => $metadata }
        });
        return $self;
    }

    # Status management
    method publish($db) {
        $db = $db->db if $db isa Registry::DAO;
        $metadata->{status} = 'published';
        $self->update($db, { metadata => { -json => $metadata } });
        return $self;
    }

    method archive($db) {
        $db = $db->db if $db isa Registry::DAO;
        $metadata->{status} = 'archived';
        $self->update($db, { metadata => { -json => $metadata } });
        return $self;
    }

    method status() {
        return $metadata->{status} // 'draft';
    }

    # Clone this program
    method clone($db, $new_name, $additional_data = {}) {
        $db = $db->db if $db isa Registry::DAO;

        my $clone_data = {
            name     => $new_name,
            slug     => lc( $new_name =~ s/\s+/-/gr ),
            metadata => { %$metadata },
            notes    => $notes,
            %$additional_data
        };

        # Mark as cloned from original
        $clone_data->{metadata}{cloned_from} = $id;
        $clone_data->{metadata}{status} = 'draft';

        return $self->create($db, $clone_data);
    }
}