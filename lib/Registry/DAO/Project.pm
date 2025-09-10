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

}