use v5.40.0;
use utf8;
use Object::Pad;

class Registry::DAO::Object {
    use Carp         qw( carp );
    use experimental qw(builtin try);
    use builtin      qw(blessed);

    sub table($) { ... }

    sub find ( $class, $db, $filter, $order = { -desc => 'created_at' } ) {
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
              ->hash->%*;
            return $class->new(%data);
        }
        catch ($e) {
            carp "Error creating $class: $e";
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
            $db->update( $self->table, $data, $filter );
            return $self;
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

    method dao($db) { Registry::DAO->new( db => $db, schema => $slug ) }

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
    field $id :param;
    field $name :param;
    field $slug :param;
    field $metadata :param;
    field $notes :param;
    field $created_at :param;

    use constant table => 'locations';

    sub create ( $class, $db, $data ) {
        $data->{slug} //= lc( $data->{name} =~ s/\s+/_/gr );
        $class->SUPER::create( $db, $data );
    }

    method id   { $id }
    method name { $name }
}

class Registry::DAO::Project :isa(Registry::DAO::Object) {
    field $id :param :reader;
    field $name :param;
    field $slug :param;
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
    field $metadata :param :reader;
    field $notes :param :reader;
    field $created_at :param :reader;

    use constant table => 'templates';

    sub import_from_file( $class, $dao, $file ) {

        my $name = $file->to_rel('templates') =~ s/.html.ep//r;

        return if $dao->find( 'Registry::DAO::Template' => { name => $name, } );

        my ( $workflow, $step ) = $name =~ /^(?:(.*)\/)?(.*)$/;
        $workflow //= '__default__';    # default workflow

        # landing is the default step
        $step = 'landing' if $step eq 'index';

        my $template = $dao->create(
            'Registry::DAO::Template' => {
                name    => $name,
                slug    => $name =~ s/\W+/-/gr,
                content => $file->slurp,
            }
        );

        if ($template) {
            my $workflow =
              $dao->find( 'Registry::DAO::Workflow' => { slug => $workflow, } );
            return $template unless $workflow;
            if ( my $step = $workflow->get_step( $dao, { slug => $step } ) ) {
                $step->set_template( $dao, $template );
            }
        }

    }
}
