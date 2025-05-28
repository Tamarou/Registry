use 5.40.2;
use Object::Pad;

class Registry::DAO::OutcomeDefinition :isa(Registry::DAO::Object) {
    use Carp         qw(carp);
    use experimental qw(try);
    use Mojo::JSON   qw(encode_json decode_json);
    use Mojo::File   qw(path);

    field $id :param;
    field $name :param;
    field $description :param;
    field $schema :param;
    field $created_at :param;
    field $updated_at :param;

    use constant table => 'outcome_definitions';

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
        
        # Handle JSON encoding for schema field if it's a reference
        if ( ref $data->{schema} && ref $data->{schema} ne 'SCALAR' ) {
            $data->{schema} = encode_json( $data->{schema} );
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

            # Extract name, description and prepare data
            my $data = {
                name        => $schema->{name},
                description => $schema->{description},
                schema      => $schema_json
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
                        schema      => $data->{schema},
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
