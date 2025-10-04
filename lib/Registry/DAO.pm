# ABOUTME: Data Access Object layer for Registry application database interactions
# ABOUTME: Provides base functionality for all DAO classes and database operations
use 5.40.2;
use utf8;
use experimental qw(builtin try);
use builtin      qw(export_lexically);
use Object::Pad;

use Mojo::Pg;
use Registry::DAO::Object;
use Registry::DAO::User;
use Registry::DAO::Tenant;
use Registry::DAO::Location;
use Registry::DAO::Program;
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
use Registry::DAO::TransferRequest;
use Registry::DAO::Program;
use Registry::DAO::Curriculum;
use Registry::DAO::ProgramTeacher;

class Registry::DAO {
    use Carp         qw(croak);
    use experimental qw(builtin try);
    use builtin      qw(blessed);

    field $url :param :reader //= $ENV{DB_URL};
    field $schema :param = 'registry';
    field $pg = do {
        my $pg_obj = Mojo::Pg->new($url);
        $pg_obj->search_path( [ $schema, 'public' ] );
        # Mojo::Pg handles UTF-8 by default, but ensure proper client encoding
        $pg_obj->on(connection => sub {
            my ($pg, $dbh) = @_;
            $dbh->do("SET client_encoding = 'UTF8'");
        });
        $pg_obj;
    };
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

    # Import workflows from YAML files into the database
    method import_workflows ($files, $verbose = 0) {
        use Mojo::File qw(path);
        use YAML::XS qw(Load);
        use Registry::DAO::Workflow;

        my $output = '';

        # Import each workflow file
        for my $file (@$files) {
            my $yaml = (ref $file ? $file : path($file))->slurp;
            next if Load($yaml)->{draft};

            try {
                my $workflow = Registry::DAO::Workflow->from_yaml($self, $yaml);
                my $step_count = scalar @{ Load($yaml)->{steps} // [] };
                my $message = sprintf "Imported workflow '%s' (%s) with %d steps",
                    $workflow->name, $workflow->slug, $step_count;

                if ($verbose) {
                    say $message;
                } else {
                    $output .= "$message\n";
                }
            }
            catch ($e) {
                my $error = "Error importing workflow: $e";
                if ($verbose) {
                    warn $error;
                } else {
                    $output .= "$error\n";
                }
            }
        }

        return $output unless $verbose;
    }
}

1;
