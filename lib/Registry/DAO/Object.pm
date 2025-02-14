use v5.40.0;
use utf8;
use Object::Pad;

class Registry::DAO::Object {
    use Carp         qw( carp );
    use experimental qw(builtin try);
    use builtin      qw(blessed);

    sub table($) { ... }

    sub find ( $class, $db, $filter, $order = { -desc => 'created_at' } ) {
        my $c = $db->select( $class->table, '*', $filter, $order )
          ->expand->hashes->map( sub { $class->new( $_->%* ) } );
        return wantarray ? $c->to_array->@* : $c->first;
    }

    sub create ( $class, $db, $data ) {
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
        my @objects = $class->find( $db, $filter );
        return @objects if @objects;
        return $class->create( $db, $data );
    }

}

class Registry::DAO::User :isa(Registry::DAO::Object) {
    use Carp         qw( carp );
    use experimental qw(try);
    use Crypt::Passphrase;

    field $id :param;
    field $username :param;
    field $passhash :param = '';
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

    method id       { $id }
    method username { $username }
    method passhash { $passhash }
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

    method primary_user ($db) {
        my ($user_id) = $db->select( 'tenant_users', 'user_id',
            { tenant_id => $id, is_primary => 1 } )->array;
        Registry::DAO::User->find( $db, { id => $user_id } );
    }

    method users ($db) {

        # TODO: this should be a join
        $db->select( 'tenant_users', '*', { tenant_id => $id } )
          ->hashes->map(
            sub { Registry::DAO::User->find( $db, { id => $_->{user_id} } ) } )
          ->to_array->@*;
    }

    method add_user ( $db, $user, $is_primary = 0 ) {
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
    field $html :param :reader;
    field $metadata :param :reader;
    field $notes :param :reader;
    field $created_at :param :reader;

    use constant table => 'templates';

    sub import_templates( $class, $dao, $log ) {

        my $registry_tenant = $dao->registry_tenant;

        my $template_dir = Mojo::File->new('templates');
        my @template_files =
          $template_dir->list_tree->grep(qr/\.html\.ep$/)->each;

        my $imported = 0;
        for my $file (@template_files) {
            my $name = $file->to_rel('templates') =~ s/.html.ep//r;

            next
              if $dao->find( 'Registry::DAO::Template' => { name => $name, } );

            my ( $workflow, $step ) = $name =~ /^(?:(.*)\/)?(.*)$/;
            $workflow //= '__default__';    # default workflow

            # landing is the default step
            $step = 'landing' if $step eq 'index';

            $log->("Importing template $name ($workflow / $step)");

            my $template = $dao->create(
                'Registry::DAO::Template' => {
                    name => $name,
                    html => $file->slurp,
                }
            );

            if ($template) {
                my $workflow = $dao->find(
                    'Registry::DAO::Workflow' => { slug => $workflow, } );

                if ( my $step = $workflow->get_step( $dao, { slug => $step } ) )
                {
                    $step->set_template( $dao, $template );
                }
            }

            $imported++;
        }
        $log->("Imported $imported templates") if $imported;
    }
}
