use v5.38.2;
use utf8;
use experimental qw(builtin);
use builtin      qw(export_lexically true false);
use Object::Pad;

use Mojo::Pg;
use Registry::DAO::Workflow;
use Registry::DAO::Events;

class Registry::DAO {
    field $url : param //= $ENV{DB_URL};
    field $schema : param = 'registry';
    field $pg = Mojo::Pg->new($url)->search_path( [ $schema, 'public' ] );
    field $db = $pg->db;

    method db  { $db }
    method url { $url }

    sub import(@) {
        no warnings;
        export_lexically(
            DAO          => sub () { 'Registry::DAO' },
            Workflow     => sub () { 'Registry::DAO::Workflow' },
            WorkflowRun  => sub () { 'Registry::DAO::WorkflowRun' },
            WorkflowStep => sub () { 'Registry::DAO::WorkflowStep' },
        );
    }

    method find ( $class, $filter = {} ) {
        $class = "Registry::DAO::$class" unless $class =~ /Registry::DAO::/;
        return $class->find( $db, $filter );
    }

    method create ( $class, $data ) {
        $class = "Registry::DAO::$class" unless $class =~ /Registry::DAO::/;
        return $class->create( $db, $data );
    }
}

class Registry::DAO::User {
    use Crypt::Passphrase;

    field $id : param;
    field $username : param;
    field $passhash : param = '';
    field $created_at : param;

    sub find ( $, $db, $filter ) {
        delete $filter->{password};
        my $data = $db->select( 'users', '*', $filter )->hash;
        return $data ? __PACKAGE__->new( $data->%* ) : ();
    }

    sub create ( $, $db, $data ) {
        my $crypt = Crypt::Passphrase->new(
            encoder    => 'Argon2',
            validators => [ 'Bcrypt', 'SHA1::Hex' ],
        );

        $data->{passhash} = $crypt->hash_password( delete $data->{password} );

        __PACKAGE__->new(
            $db->insert( 'users', $data, { returning => '*' } )->hash->%* );
    }

    sub find_or_create ( $class, $db, $data ) {
        return ( find( $class, $db, $data ) || create( $class, $db, $data ) );
    }

    method id       { $id }
    method username { $username }
}

class Registry::DAO::Customer {
    field $id : param;
    field $name : param;
    field $slug : param;
    field $created_at : param;
    field $primary_user_id : param;

    sub find ( $class, $db, $filter ) {
        my $data = $db->select( 'customers', '*', $filter )->hash;
        return $data ? $class->new( $data->%* ) : ();
    }

    sub create ( $class, $db, $data ) {
        $class->new(
            $db->insert( 'customers', $data, { returning => '*' } )->hash->%* );
    }

    method id   { $id }
    method name { $name }
    method slug { $slug }

    method primary_user ($db) {
        Registry::DAO::User->find( $db, { id => $primary_user_id } );
    }

    method users ($db) {

        # TODO: this should be a join
        $db->select( 'customer_users', '*', { customer_id => $id } )
          ->hashes->map(
            sub { Registry::DAO::User->find( $db, { id => $_->{user_id} } ) } )
          ->to_array->@*;
    }

    method add_user ( $db, $user ) {
        $db->insert(
            'customer_users',
            { customer_id => $id, user_id => $user->id },
            { returning   => '*' }
        );
    }
}

class Registry::DAO::RegisterCustomer : isa(Registry::DAO::WorkflowStep) {

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my $run = $workflow->latest_run($db);

        my $user_data = $run->data->{users};
        my @users =
          map { Registry::DAO::User->find_or_create( $db, $_ ) } $user_data->@*;

        my $profile = $run->data->{profile};
        $profile->{primary_user_id} = $users[0]->id;

        my $customer = Registry::DAO::Customer->create( $db, $profile );

        $customer->add_user( $db, $_ ) for @users;

        $db->query( 'SELECT clone_schema(dest_schema => ?)', $customer->slug );

        $db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)',
            $customer->slug, $_->id )
          for @users;

        # return the data to be stored in the workflow run
        return { customer => $customer->id };
    }
}

class Registry::DAO::CreateEvent : isa(Registry::DAO::WorkflowStep) {

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my ($run)      = $workflow->latest_run($db);
        my $event = Registry::DAO::Event->create( $db, $run->data->{info} );

        return { event => $event->id };
    }
}

class Registry::DAO::CreateSession : isa(Registry::DAO::WorkflowStep) {

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my ($run)      = $workflow->latest_run($db);

        my $data   = $run->data->{info};
        my $events = delete $data->{events};

        # Mojolicious unwinds form posts of only one value
        $events = [$events] unless ref $events eq 'ARRAY';

        my $session = Registry::DAO::Session->create( $db, $data );
        $session->add_events( $db, $events->@* );

        return { session => $session->id };
    }
}

class Registry::DAO::Location {
    field $id : param;
    field $name : param;
    field $slug : param;
    field $metadata : param;
    field $notes : param;
    field $created_at : param;

    sub find ( $, $db, $filter ) {
        my $data = $db->select( 'locations', '*', $filter )->hash;
        return $data ? __PACKAGE__->new( $data->%* ) : ();
    }

    sub create ( $, $db, $data ) {
        $data->{slug} //= $data->{name} =~ s/\s+/_/gr;
        __PACKAGE__->new(
            $db->insert( 'locations', $data, { returning => '*' } )->hash->%* );
    }

    method id   { $id }
    method name { $name }
}

class Registry::DAO::Project {
    field $id : param;
    field $name : param;
    field $slug : param;
    field $metadata : param;
    field $notes : param;
    field $created_at : param;

    sub find ( $, $db, $filter ) {
        my $data = $db->select( 'projects', '*', $filter )->hash;
        return $data ? __PACKAGE__->new( $data->%* ) : ();
    }

    sub create ( $, $db, $data ) {
        $data->{slug} //= $data->{name} =~ s/\s+/_/gr;
        __PACKAGE__->new(
            $db->insert( 'projects', $data, { returning => '*' } )->hash->%* );
    }

    method id { $id }
}
