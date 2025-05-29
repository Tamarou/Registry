use 5.40.2;
use Object::Pad;

class Registry::DAO::Location :isa(Registry::DAO::Object) {
    use Mojo::JSON qw(decode_json encode_json);

    field $id :param :reader;
    field $name :param :reader;
    field $slug :param :reader;
    field $address_info :param :reader = {};
    field $contact_info :param :reader = {};
    field $facilities :param :reader   = {};
    field $capacity :param :reader;
    field $metadata :param :reader = {};
    field $notes :param :reader;
    field $created_at :param :reader;

    use constant table => 'locations';

    sub create ( $class, $db, $data ) {
        for my $field (qw(address_info contact_info facilities metadata)) {
            next unless exists $data->{$field};
            $data->{$field} = { -json => $data->{$field} };
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
}