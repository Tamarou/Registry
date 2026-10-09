use 5.42.0;
use Object::Pad;

class Registry::DAO::OutcomeDefinition :isa(Registry::DAO::Object) {
    use Carp         qw(carp);

    use Mojo::JSON   qw(encode_json decode_json);
    use Mojo::File   qw(path);

    field $id :param;
    field $name :param;
    field $description :param;
    field $schema :param;
    field $created_at :param;
    field $updated_at :param;

    sub table { 'outcome_definitions' }

    method id          { $id }
    method name        { $name }
    method description { $description }
    method schema      { $schema }

    method validate ($data) {
        # In a real implementation, we would use JSON::Validator
        # For now, we'll just return true for basic testing
        return 1;
    }

   # Override the parent's create method to handle JSON encoding and remove slug
    sub create ( $class, $db, $data ) {
        # Handle database connection
        $db = $db->db if $db isa Registry::DAO;
        
        # -json, not encode_json. encode_json returns UTF-8 ENCODED BYTES, and
        # handing those to a jsonb column gets them encoded a second time on the
        # way to Postgres, so a schema property whose name carried an accent was
        # stored mojibaked -- the accented character replaced by the two
        # characters its UTF-8 bytes look like in Latin-1 -- and came back that
        # way for ever after. Mojo::Pg's -json takes the structure and encodes it
        # exactly once, which is what every other DAO here does.
        #
        # Found by #468, which restored t/integration/utf8-encoding.t: the file
        # had never run, so its UTF-8 assertions had never reported this.
        #
        # Deliberately ASCII. This file has no `use utf8`, and a non-ASCII byte
        # in a comment here segfaults perl at load time -- not a compile error,
        # a SEGV, and `perl -c` on the file alone still passes.
        if ( ref $data->{schema} && ref $data->{schema} ne 'SCALAR' ) {
            $data->{schema} = { -json => $data->{schema} };
        }

        # Remove slug field as it doesn't exist in the database
        delete $data->{slug};

        # Call parent's create method
        return $class->SUPER::create( $db, $data );
    }

    # This method is specific to OutcomeDefinition and not in the parent class
    sub import_from_file ( $class, $db, $file ) {
        $db = $db->db if $db isa Registry::DAO;
        
        try {
            # Convert to Mojo::File if it's a string
            $file = path($file) unless ref $file;
            
            # Load the JSON schema file
            my $schema_json = $file->slurp;
            my $schema = decode_json($schema_json);

            # The DECODED structure, not the slurped bytes. slurp returns bytes
            # and decode_json turns them into characters; storing $schema_json
            # put the bytes into a jsonb column to be encoded again -- the same
            # double encoding create() had.
            my $data = {
                name        => $schema->{name},
                description => $schema->{description},
                schema      => $schema,
            };

            # Check if outcome definition with this name already exists
            my ($existing) = $class->find( $db, { name => $data->{name} } );

            my $outcome;
            if ($existing) {
                # Update the existing record
                $db->update(
                    $class->table,
                    {
                        description => $data->{description},
                        schema      => { -json => $data->{schema} },
                        updated_at  => \'now()'
                    },
                    { id => $existing->id }
                );

                # Reload the object to get updated values
                $outcome = $class->find( $db, { id => $existing->id } );
            }
            else {
                # Create new definition
                $outcome = $class->create( $db, $data );
            }

            return $outcome;
        }
        catch ($e) {
            carp "Error importing outcome definition from file: $e";
            return;
        }
    }
}

1;
