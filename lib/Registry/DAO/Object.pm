use v5.40.0;
use utf8;
use Object::Pad;

class Registry::DAO::Object {
    use Carp         qw( carp confess );
    use experimental qw(builtin try);
    use builtin      qw(blessed);

    sub table($) { ... }

    sub find ( $class, $db, $filter = {}, $order = { -desc => 'created_at' } ) {
        $db = $db->db if $db isa Registry::DAO;
        my $c = $db->select( $class->table, '*', $filter, $order )
          ->expand->hashes->map( sub { $class->new( $_->%* ) } );
        return wantarray ? $c->to_array->@* : $c->first;
    }

    sub create ( $class, $db, $data ) {
        $db = $db->db if $db isa Registry::DAO;
        try {
            my %data =
              $db->insert( $class->table, $data, { returning => '*' } )
              ->expand->hash->%*;
            return $class->new(%data);
        }
        catch ($e) {
            confess "Error creating $class: $e";
        };
    }

    sub find_or_create ( $class, $db, $filter, $data = $filter ) {
        $db = $db->db if $db isa Registry::DAO;
        if ( my @objects = $class->find( $db, $filter ) ) {
            return unless defined wantarray;
            return wantarray ? @objects : $objects[0];
        }
        return $class->create( $db, $data );
    }

    method update ( $db, $data, $filter = { id => $self->id } ) {
        $db = $db->db if $db isa Registry::DAO;
        try {
            my $new =
              $db->update( $self->table, $data, $filter, { returning => '*' } )
              ->expand->hash;
            return blessed($self)->new( $new->%* );
        }
        catch ($e) {
            carp "Error updating $self: $e";
        };
    }
}

class Registry::DAO::User :isa(Registry::DAO::Object) {
    use Carp         qw( carp );
    use experimental qw(try);
    use Crypt::Passphrase;

    field $id :param :reader;
    field $username :param :reader;
    field $passhash :param :reader = '';
    field $created_at :param;

    use constant table => 'users';

    sub find ( $class, $db, $filter, $order = { -desc => 'created_at' } ) {
        delete $filter->{password};
        my $data =
          $db->select( $class->table, '*', $filter, $order )->expand->hash;

        return $data ? $class->new( $data->%* ) : ();
    }

    sub create ( $class, $db, $data //= carp "must provide data" ) {
        try {
            my $crypt = Crypt::Passphrase->new(
                encoder    => 'Argon2',
                validators => [ 'Bcrypt', 'SHA1::Hex' ],
            );

            $data->{passhash} =
              $crypt->hash_password( delete $data->{password} );
            my %data =
              $db->insert( $class->table, $data, { returning => '*' } )
              ->hash->%*;
            return $class->new(%data);
        }
        catch ($e) {
            carp "Error creating $class: $e";
        };
    }

}

class Registry::DAO::Tenant :isa(Registry::DAO::Object) {
    field $id :param :reader = undef;
    field $name :param :reader;
    field $slug :param :reader //= lc( $name =~ s/\s+/_/gr );
    field $created_at :param :reader;

    use constant table => 'tenants';

    sub create ( $class, $db, $data ) {
        $data->{slug} //= lc( $data->{name} =~ s/\s+/_/gr );
        $class->SUPER::create( $db, $data );
    }

    method dao($db = undef) { 
        # If we have a db handle that's part of a Registry::DAO object, get the URL from there
        if ($db && $db isa Registry::DAO) {
            return Registry::DAO->new( url => $db->url, schema => $slug );
        } 
        # If we have a raw database handle, connect using ENV{DB_URL}
        elsif ($db) {
            return Registry::DAO->new( schema => $slug );
        } 
        # No db handle, just use the default URL
        else {
            return Registry::DAO->new( schema => $slug );
        }
    }

    method primary_user ($db) {
        my $sql = <<~'SQL';
            SELECT u.*
            FROM users u
            INNER JOIN tenant_users tu ON u.id = tu.user_id
            WHERE tu.tenant_id = ? AND tu.is_primary is true
            SQL
        my $user_data = $db->query( $sql, $id )->expand->hash;
        return Registry::DAO::User->new( $user_data->%* );
    }

    method users ($db) {

        # TODO: this should be a join
        $db->select( 'tenant_users', '*', { tenant_id => $id } )
          ->hashes->map(
            sub { Registry::DAO::User->find( $db, { id => $_->{user_id} } ) } )
          ->to_array->@*;
    }

    method set_primary_user ( $db, $user ) {
        $db->insert(
            'tenant_users',
            {
                tenant_id  => $id,
                user_id    => $user->id,
                is_primary => 1
            },
            {
                on_conflict => [
                    [ 'tenant_id', 'user_id' ] => { is_primary => 1 }
                ]
            }
        );
    }

    method add_user ( $db, $user, $is_primary = 0 ) {
        Carp::croak 'user must be a Registry::DAO::User'
          unless $user isa Registry::DAO::User;
        $db->insert(
            'tenant_users',
            {
                tenant_id  => $id,
                user_id    => $user->id,
                is_primary => $is_primary ? 1 : 0
            },
            { returning => '*' }
        );
    }
}

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

class Registry::DAO::Project :isa(Registry::DAO::Object) {
    field $id :param :reader;
    field $name :param;
    field $slug :param;

    # TODO: Project class needs:
    # - Remove metadata default value
    # - Add BUILD to decode JSON strings
    # - Use { -json => $metadata } in create/update
    # - Add explicit metadata() accessor
    field $metadata :param;
    field $notes :param;
    field $created_at :param;

    use constant table => 'projects';

    sub create ( $class, $db, $data ) {
        $data->{slug} //= lc( $data->{name} =~ s/\s+/_/gr );
        $class->SUPER::create( $db, $data );
    }

}

class Registry::DAO::Template :isa(Registry::DAO::Object) {
    field $id :param :reader;
    field $name :param :reader;
    field $slug :param :reader    = lc( $name =~ s/\s+/-/gr );
    field $content :param :reader = '';

    # TODO: Template class needs:
    # - Remove :reader metadata field
    # - Add BUILD for JSON decoding
    # - Handle { -json => $metadata } in create
    # - Add explicit metadata() accessor
    field $metadata :param :reader;
    field $notes :param :reader;
    field $created_at :param :reader;

    use constant table => 'templates';

    sub import_from_file( $class, $dao, $file ) {
        # Parse the template name from the file path
        my $name = $file->to_rel('templates') =~ s/.html.ep//r;
        
        # Generate a sensible slug from the name for special slug handling
        my $slug;
        if ($name =~ m{^(.*)/index$}) {
            # For 'workflow/index' files, create a slug like 'workflow-index'
            # This handles the case where a template is referenced as 'workflow-index' in YAML
            $slug = lc( "$1-index" =~ s/\W+/-/gr );
        } else {
            # Normal slug generation
            $slug = lc( $name =~ s/\W+/-/gr );
        }
        
        # Check if template exists by name or slug (allowing for different ways to reference it)
        my $template = $dao->find( 'Registry::DAO::Template' => { name => $name } )
                    || $dao->find( 'Registry::DAO::Template' => { slug => $slug } );
        
        # If it exists, update the content if necessary
        if ($template) {
            my $content = $file->slurp;
            if ($template->content ne $content) {
                $template = $template->update( $dao->db, { content => $content });
            }
            return $template;
        }
        
        # Create new template
        my $content = $file->slurp;
        $template = $dao->create(
            'Registry::DAO::Template' => {
                name    => $name,
                slug    => $slug,
                content => $content,
            }
        );
        
        # Try to link the template to a workflow step if it matches the pattern
        if ($template) {
            my ( $workflow_name, $step ) = $name =~ /^(?:(.*)\/)?(.*)$/;
            
            # Skip if no workflow name found
            return $template unless $workflow_name;
            
            # Handle index template special case (as landing)
            $step = 'landing' if $step eq 'index';
            
            # Try to find the workflow by slug
            my $workflow = $dao->find( 'Registry::DAO::Workflow' => { slug => $workflow_name });
            return $template unless $workflow;
            
            # Try to find the step in the workflow
            my $workflow_step = $workflow->get_step( $dao->db, { slug => $step });
            return $template unless $workflow_step;
            
            # Set the template on the step
            $workflow_step->set_template( $dao->db, $template );
        }
        
        return $template;
    }
}
