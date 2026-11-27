# ABOUTME: session-setup's first step: choose one of this tenant's programs, or create one, and where its sessions meet.
# ABOUTME: Records session_program => { project_id, location_id }; a program is a projects row that is not a class.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::SessionProgram :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Location;
    use Registry::DAO::Project;
    use Registry::DAO::Tenant;

    my $UUID = qr/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i;

    # This schema's programs: a project without seats per occurrence (a class has them).
    sub programs ( $class, $db ) {
        return Registry::DAO::Project->find( $db, { seats_per_occurrence => undef }, { -asc => 'name' } );
    }

    # Only an admin of this schema's tenant may set up sessions: a workflow
    # composed around these steps is not gated by slug, as ClassBasics says.
    sub refuse_non_admin ( $class, $db, $run ) {
        my $user   = $run && ref $run->data->{user} eq 'HASH' ? $run->data->{user} : {};
        my $tenant = $db->query('SELECT current_schema()')->array->[0];
        return ( Registry::DAO::Tenant->role_in( $db, $tenant, $user->{id} ) // '' ) eq 'admin'
            ? undef
            : { stay => 1, errors => ['Only an administrator of this tenant can set up sessions'] };
    }

    method process ( $db, $form_data, $run = undef ) {
        if ( my $refused = __PACKAGE__->refuse_non_admin( $db, $run ) ) { return $refused }

        my %f = map { $_ => ( ref $form_data->{$_} ? '' : $form_data->{$_} // '' ) }
            qw( program_mode project_id program_name location_id );

        # Also what a run's start, which submits only the seeded user, gets.
        return { stay => 1, errors => ['Choose one of your programs, or create one'] }
            unless $f{program_mode} eq 'existing' || $f{program_mode} eq 'create';

        my @errors;
        my $location_ok = $f{location_id} =~ $UUID && Registry::DAO::Location->find( $db, { id => $f{location_id} } );
        push @errors, 'Choose one of your locations' unless $location_ok;

        if ( $f{program_mode} eq 'existing' ) {
            my ($program) = $f{project_id} =~ $UUID && grep { $_->id eq $f{project_id} } __PACKAGE__->programs($db);
            push @errors, 'Choose one of your programs' unless $program;
            return { stay => 1, errors => \@errors } if @errors;
            return { session_program => { project_id => $program->id, location_id => $f{location_id} } };
        }

        my $name = $f{program_name} =~ s/\A\s+|\s+\z//gr;
        unshift @errors, 'Name the program' unless length $name;
        return { stay => 1, errors => \@errors } if @errors;

        # One program per run: the run's row is locked while this reads whether
        # it has created one, so a repeated submission finds the first.
        my $tx = $db->dbh->{AutoCommit} ? $db->begin : undef;
        my $created = $db->query( q{
            SELECT data->>'created_program_id' FROM workflow_runs WHERE id = ? FOR UPDATE
        }, $run->id )->array->[0];
        unless ($created) {
            $db->query('SAVEPOINT session_program') unless $tx;
            $created = eval { Registry::DAO::Project->create( $db, { name => $name } )->id };
            unless ($created) {
                $db->query('ROLLBACK TO SAVEPOINT session_program') unless $tx;
                return { stay => 1, errors => ['Could not create the program: is the name already in use?'] };
            }
            $db->query('RELEASE SAVEPOINT session_program') unless $tx;
            $run->update_data( $db, { created_program_id => $created } );
        }
        $tx->commit if $tx;

        return { session_program => { project_id => $created, location_id => $f{location_id} } };
    }

    method prepare_template_data ( $db, $run, $params = {} ) {
        return {
            programs  => [ __PACKAGE__->programs($db) ],
            locations => Registry::DAO::Location->list($db),
        };
    }
}

1;
