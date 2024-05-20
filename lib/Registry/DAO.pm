use v5.38.2;
use utf8;
use experimental qw(class builtin);
use builtin      qw(export_lexically true false);

use Mojo::Pg;
use Registry::DAO::Workflow;

class Registry::DAO {
    field $url : param //= $ENV{DB_URL};
    field $schema = 'registry';
    field $pg     = Mojo::Pg->new($url)->search_path( [ $schema, 'public' ] );
    field $db     = $pg->db;

    method db { $db }

    sub import(@) {
        export_lexically(
            DAO          => sub () { 'Registry::DAO' },
            Workflow     => sub () { 'Registry::DAO::Workflow' },
            WorkflowRun  => sub () { 'Registry::DAO::WorkflowRun' },
            WorkflowStep => sub () { 'Registry::DAO::WorkflowStep' },
        );
    }

    method find ( $class, $filter ) {
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
    field $created_at : param;
    field $primary_user_id : param;

    sub find ( $class, $db, $filter ) {
        $class->new( $db->select( 'customers', '*', $filter )->hash->%* );
    }

    sub create ( $class, $db, $data ) {
        $class->new(
            $db->insert( 'customers', $data, { returning => '*' } )->hash->%* );
    }

    sub find_or_create ( $class, $db, $data ) {
        return ( find( $class, $db, $data ) || create( $class, $db, $data ) );
    }

    method id   { $id }
    method name { $name }

    method primary_user ($db) {
        Registry::DAO::User->find( $db, { id => $primary_user_id } );
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
        my $run = $self->workflow($db)->latest_run($db);

        my $user_data = $run->data->{users};
        my @users =
          map { Registry::DAO::User->find_or_create( $db, $_ ) } $user_data->@*;

        my $profile = $run->data->{profile};
        $profile->{primary_user_id} = $users[0]->id;

        my $customer = Registry::DAO::Customer->create( $db, $profile );

        $customer->add_user( $db, $_ ) for @users;

        # return the data to be stored in the workflow run
        return { customer => $customer->id };
    }
}

class Registry::DAO::Collection {
    field $id : param;
    field $slug : param;
    field $notes : param;
    field $created_at : param;

    sub find ( $db, $filter ) {
        __PACKAGE__->new(
            $db->select( 'collections', '*', $filter )->hash->%* );
    }

    sub create ( $db, $data ) {
        __PACKAGE__->new(
            $db->insert( 'collections', $data, { returning => '*' } )
              ->hash->%* );
    }

    sub find_or_create ( $db, $data ) {
        return ( find( $db, $data ) || create( $db, $data ) );
    }

}

class Registry::DAO::Product {
    field $id : param;
    field $slug : param;
    field $notes : param;
    field $created_at : param;

    sub find ( $db, $filter ) {
        __PACKAGE__->new( $db->select( 'products', '*', $filter )->hash->%* );
    }

    sub create ( $db, $data ) {
        __PACKAGE__->new(
            $db->insert( 'products', $data, { returning => '*' } )->hash->%* );
    }

    sub find_or_create ( $db, $data ) {
        return ( find( $db, $data ) || create( $db, $data ) );
    }

}

class Registry::DAO::Lesson {

    sub find ( $db, $filter ) {
        __PACKAGE__->new( $db->select( 'lessons', '*', $filter )->hash->%* );
    }

    sub create ( $db, $data ) {
        __PACKAGE__->new(
            $db->insert( 'lessons', $data, { returning => '*' } )->hash->%* );
    }

    sub find_or_create ( $db, $data ) {
        return ( find( $db, $data ) || create( $db, $data ) );
    }
}

class Registry::DAO::Event {
    field $duration : param;
    field $id : param;
    field $lession_id : param;
    field $location_id : param;
    field $metadata : param;
    field $notes : param;
    field $product_id : param;
    field $time : param;

    sub find ( $db, $filter ) {
        __PACKAGE__->new( $db->select( 'events', '*', $filter )->hash->%* );
    }

    sub create ( $db, $data ) {
        __PACKAGE__->new(
            $db->insert( 'events', $data, { returning => '*' } )->hash->%* );
    }

    sub find_or_create ( $db, $data ) {
        __PACKAGE__->new(
            $db->insert(
                'events', $data,
                {
                    on_conflict => [
                        [ 'product_id', 'lesson_id', 'location_id', 'time' ] =>
                          {
                            product_id  => \'EXCLUDED.product_id',
                            location_id => \'EXCLUDED.location_id',
                            time        => \'EXCLUDED.time',
                          }
                    ],
                    returning => '*'
                }
            )->hash->%*
        );
    }

}    # classes / days

