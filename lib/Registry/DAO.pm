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

