use 5.40.2;
use utf8;
use experimental qw(builtin);
use builtin      qw(export_lexically);
use Object::Pad;

use Mojo::Pg;
use Registry::DAO::Object;
use Registry::DAO::User;
use Registry::DAO::Tenant;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::Template;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::WorkflowRun;
use Registry::DAO::Event;
use Registry::DAO::Session;
use Registry::DAO::Enrollment;
use Registry::DAO::SessionTeacher;
use Registry::DAO::WorkflowSteps;
use Registry::DAO::Family;
use Registry::DAO::FamilyMember;
use Registry::DAO::OutcomeDefinition;
use Registry::DAO::CreateOutcomeDefinition;

class Registry::DAO {
    use Carp         qw(croak);
    use experimental qw(builtin try);
    use builtin      qw(blessed);

    field $url :param :reader //= $ENV{DB_URL};
    field $schema :param = 'registry';
    field $pg = Mojo::Pg->new($url)->search_path( [ $schema, 'public' ] );
    field $db :reader = $pg->db;

    sub import(@) {
        no warnings;
        export_lexically(
            DAO               => sub () { 'Registry::DAO' },
            Workflow          => sub () { 'Registry::DAO::Workflow' },
            WorkflowRun       => sub () { 'Registry::DAO::WorkflowRun' },
            WorkflowStep      => sub () { 'Registry::DAO::WorkflowStep' },
            OutcomeDefinition => sub () { 'Registry::DAO::OutcomeDefinition' },
        );
    }

    method begin() { $db->begin }

    method query ( $sql, @params ) {
        return unless defined wantarray;

        my $res = $db->query( $sql, @params )->expand->hashes;
        wantarray ? $res->to_array->@* : $res->first;
    }

    method select ( $table, $fields = undef, $where = undef, $options = undef ) {
        return $db->select( $table, $fields, $where, $options );
    }

    method delete ( $table, $where = undef ) {
        return $db->delete( $table, $where );
    }

    method find ( $class, $filter = {} ) {
        return unless defined wantarray;

        $class = "Registry::DAO::$class" unless $class =~ /Registry::DAO::/;
        return $class->find( $db, $filter );
    }

    method create ( $class, $data ) {
        return unless defined wantarray;

        $class = "Registry::DAO::$class" unless $class =~ /Registry::DAO::/;
        try { return $class->create( $db, $data ) }
        catch ($e) { croak "Error creating $class: $e" };
    }

    method connect_schema ($schema) {
        return blessed($self)->new( url => $url, schema => $schema );
    }

    method schema ($new_schema = undef) {
        return $new_schema ? $self->connect_schema($new_schema) : $schema;
    }

    method registry_tenant() {
        return $self->find( 'Registry::DAO::Tenant', { slug => 'registry' } );
    }

    method current_tenant { $schema }
}
