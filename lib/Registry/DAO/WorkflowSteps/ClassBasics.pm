# ABOUTME: in-studio-class-setup's first step: choose one of this tenant's classes, or create one.
# ABOUTME: A class is a projects row with seats per occurrence and its location; it creates no resource.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::ClassBasics :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Location;
    use Registry::DAO::Project;
    use Registry::DAO::Tenant;

    my $UUID = qr/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i;

    # This schema's classes: a project with seats per occurrence is one.
    sub classes ( $class, $db ) {
        return Registry::DAO::Project->find( $db, { seats_per_occurrence => { '!=' => undef } }, { -asc => 'name' } );
    }

    method process ( $db, $form_data, $run = undef ) {
        my %f = map { $_ => ( ref $form_data->{$_} ? '' : $form_data->{$_} // '' ) }
            qw( class_mode class_project_id class_name location_id seats_per_occurrence );

        # The run's user, seeded server-side, and their role in this schema's
        # tenant: a workflow staff composed around this step is not gated by
        # slug, so the step checks for itself, as CreateResource does.
        my $user   = $run && ref $run->data->{user} eq 'HASH' ? $run->data->{user} : {};
        my $tenant = $db->query('SELECT current_schema()')->array->[0];
        return { stay => 1, errors => ['Only an administrator of this tenant can set up a class'] }
            unless ( Registry::DAO::Tenant->role_in( $db, $tenant, $user->{id} ) // '' ) eq 'admin';

        # Unqualified, so only this schema's classes and locations are found.
        if ( $f{class_mode} eq 'existing' ) {
            my ($class) = $f{class_project_id} =~ $UUID
                && grep { $_->id eq $f{class_project_id} } __PACKAGE__->classes($db);
            return { stay => 1, errors => ['Choose one of your classes'] } unless $class;
            return { resource_choice => { mode => 'class', class_project_id => $class->id } };
        }

        # Also what a run's start, which submits only the seeded user, gets.
        return { stay => 1, errors => ['Choose one of your classes, or create one'] }
            unless $f{class_mode} eq 'create';

        my $name = $f{class_name} =~ s/\A\s+|\s+\z//gr;
        my @errors;
        push @errors, 'Name the class' unless length $name;
        push @errors, 'Choose one of your locations'
            unless $f{location_id} =~ $UUID && Registry::DAO::Location->find( $db, { id => $f{location_id} } );
        # Nine digits at most, so every accepted number fits the integer column.
        push @errors, 'Seats per occurrence must be a whole number of at least one'
            unless $f{seats_per_occurrence} =~ /\A[1-9][0-9]{0,8}\z/;
        return { stay => 1, errors => \@errors } if @errors;

        # One class per run: the run's row is locked while this reads whether
        # it has created one, so a repeated submission finds the first.
        my $tx = $db->dbh->{AutoCommit} ? $db->begin : undef;
        my $created = $db->query( q{
            SELECT data->>'created_class_id' FROM workflow_runs WHERE id = ? FOR UPDATE
        }, $run->id )->array->[0];
        unless ($created) {
            # In a caller's transaction, a savepoint, so a refused insert
            # leaves that transaction usable, as PublishOfferVersion does.
            $db->query('SAVEPOINT class_basics') unless $tx;
            # The location goes in metadata, as Session keeps its location_id.
            $created = eval {
                Registry::DAO::Project->create( $db, {
                    name                 => $name,
                    seats_per_occurrence => 0 + $f{seats_per_occurrence},
                    metadata             => { location_id => $f{location_id} },
                } )->id;
            };
            unless ($created) {
                $db->query('ROLLBACK TO SAVEPOINT class_basics') unless $tx;
                return { stay => 1, errors => ['Could not create the class: is the name already in use?'] };
            }
            $db->query('RELEASE SAVEPOINT class_basics') unless $tx;
            $run->update_data( $db, { created_class_id => $created } );
        }
        $tx->commit if $tx;

        return { resource_choice => { mode => 'class', class_project_id => $created } };
    }

    method prepare_template_data ( $db, $run, $params = {} ) {
        return {
            classes   => [ __PACKAGE__->classes($db) ],
            locations => Registry::DAO::Location->list($db),
        };
    }
}

1;
