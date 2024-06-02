use v5.38.2;
use utf8;
use experimental qw(builtin try);
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
    use Carp         qw( croak );
    use experimental qw(try);

    field $id : param = undef;
    field $name : param;
    field $slug : param //= $name =~ s/\s+/_/gr;
    field $created_at : param;
    field $primary_user_id : param;

    sub find ( $class, $db, $filter ) {
        my $data = $db->select( 'customers', '*', $filter )->hash;
        return $data ? $class->new( $data->%* ) : ();
    }

    sub create ( $class, $db, $data ) {
        try {
            $data->{slug} //= $class->new( $data->%* )->slug;
        }
        catch ($e) {
            croak $e;
        };

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

        # TODO this should be data from a continuation not created here
        my $user_data = $run->data->{users};
        my @users =
          map { Registry::DAO::User->find_or_create( $db, $_ ) } $user_data->@*;

        my $profile = $run->data;
        delete $profile->{users};    # TODO clean this up in the workflow
        $profile->{primary_user_id} = $users[0]->id;

        my $customer = Registry::DAO::Customer->create( $db, $profile );

        $customer->add_user( $db, $_ ) for @users;

        $db->query( 'SELECT clone_schema(dest_schema => ?)', $customer->slug );

        $db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)',
            $customer->slug, $_->id )
          for @users;

        if ( $run->has_continuation ) {
            my ($continuation) = $run->continuation($db);
            my $customers = $continuation->data->{customers} // [];
            push $customers->@*, $customer->id;
            $continuation->update_data( $db, { customers => $customers } );
        }

        # return the data to be stored in the workflow run
        return { customer => $customer->id };
    }
}

class Registry::DAO::CreateEvent : isa(Registry::DAO::WorkflowStep) {

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my ($run)      = $workflow->latest_run($db);
        my $data       = $run->data;

        # grab stuff that might have come from a continuation
        if ( $data->{locations} ) {
            $data->{location_id} //= $data->{locations}->[0];
        }

        if ( $data->{users} ) {
            $data->{teacher_id} //= $data->{users}->[0];
        }

        if ( $data->{projects} ) {
            $data->{project_id} //= $data->{projects}->[0];
        }

        # only include keys that have values
        my @keys = grep $data->{$_} => qw(
          time
          duration
          location_id
          project_id
          teacher_id
          metadata
          notes
        );

        my $event = Registry::DAO::Event->create( $db, { $data->%{@keys}, } );

        if ( $run->has_continuation ) {
            my ($continuation) = $run->continuation($db);
            my $events = $continuation->data->{events} // [];
            push $events->@*, $event->id;
            $continuation->update_data( $db, { events => $events } );
        }

        return { event => $event->id };
    }
}

class Registry::DAO::CreateSession : isa(Registry::DAO::WorkflowStep) {

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my ($run)      = $workflow->latest_run($db);

        my $data   = $run->data;
        my $events = $data->{events};

        # Mojolicious unwinds form posts of only one value
        $events = [$events] unless ref $events eq 'ARRAY';

        my $session = Registry::DAO::Session->create( $db,
            { $data->%{ 'name', 'metadata', 'notes' } } );
        $session->add_events( $db, $events->@* );

        if ( $run->has_continuation ) {
            my ($continuation) = $run->continuation($db);
            my $sessions = $continuation->data->{sessions} // [];
            push $sessions->@*, $session->id;
            $continuation->update_data( $db, { sessions => $sessions } );
        }

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
