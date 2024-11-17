use v5.40.0;
use utf8;
use experimental qw(builtin);
use builtin      qw(export_lexically);
use Object::Pad;

use Mojo::Pg;
use Registry::DAO::Object;
use Registry::DAO::Workflow;
use Registry::DAO::Events;
use Registry::DAO::WorkflowSteps;

class Registry::DAO {
    use experimental qw(builtin);
    use builtin      qw(blessed);

    field $url :param :reader//= $ENV{DB_URL};
    field $schema : param = 'registry';
    field $pg = Mojo::Pg->new($url)->search_path( [ $schema, 'public' ] );
    field $db :reader = $pg->db;

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

    method connect_schema ($schema) {
        return blessed($self)->new( url => $url, schema => $schema );
    }
}
