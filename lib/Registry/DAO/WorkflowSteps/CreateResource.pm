# ABOUTME: offer-publishing's first step: use an existing resource, create one in the run's schema, or cover a class.
# ABOUTME: A finite resource has a capacity and may be bound to one occurrence; an unbounded one has neither.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::CreateResource :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Project;
    use Registry::DAO::Resource;
    use Registry::DAO::Tenant;

    my $UUID = qr/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i;

    method process ( $db, $form_data, $run = undef ) {
        my %f = map { $_ => ( ref $form_data->{$_} ? '' : $form_data->{$_} // '' ) }
            qw( resource_mode resource_name resource_kind capacity event_id class_project_id );

        # The run's user, which the controller seeds server-side, never the
        # form's, and their role in the tenant whose schema the run is in: the
        # per-slug role gate does not cover a workflow staff composed around
        # this step, so the step checks for itself, as PublishOfferVersion does.
        my $user   = $run && ref $run->data->{user} eq 'HASH' ? $run->data->{user} : {};
        my $tenant = $db->query('SELECT current_schema()')->array->[0];
        return { stay => 1, errors => ['Only an administrator of this tenant can choose what an offer sells'] }
            unless ( Registry::DAO::Tenant->role_in( $db, $tenant, $user->{id} ) // '' ) eq 'admin';

        return { resource_choice => { mode => 'existing' } } if $f{resource_mode} eq 'existing';

        # The class key every occurrence-resource of the class, now and later,
        # is covered by; only this schema's classes are found.
        if ( $f{resource_mode} eq 'class' ) {
            my $class = $f{class_project_id} =~ $UUID
                && Registry::DAO::Project->find( $db, { id => $f{class_project_id} } );
            return { stay => 1, errors => ['Choose one of your classes'] } unless $class;
            return { resource_choice => { mode => 'class', class_project_id => $class->id } };
        }

        # Also what a run's start, which submits only the seeded user, gets.
        return { stay => 1, errors => ['Choose an existing resource, create one, or cover a class'] }
            unless $f{resource_mode} eq 'create';

        my $name   = $f{resource_name} =~ s/\A\s+|\s+\z//gr;
        my $finite = $f{resource_kind} eq 'finite';

        my @errors;
        push @errors, 'Name the resource' unless length $name;
        push @errors, 'Choose whether the resource is finite or unbounded'
            unless $finite || $f{resource_kind} eq 'unbounded';
        # Nine digits at most, so every accepted capacity fits the integer column.
        push @errors, 'Capacity must be a whole number of at least one'
            if $finite && $f{capacity} !~ /\A[1-9][0-9]{0,8}\z/;

        # Only a finite resource is an occurrence, and a session's day is
        # none. Unqualified, so another tenant's occurrence names nothing here.
        my $event_id = $finite && length $f{event_id} ? $f{event_id} : undef;
        if ( defined $event_id ) {
            # The run's own resource doesn't count, so a resubmitted create finds it below.
            my $free = $event_id =~ $UUID ? $db->query( q{
                SELECT NOT EXISTS (SELECT 1 FROM resources r
                                    WHERE r.event_id = e.id AND r.id IS DISTINCT FROM ?::uuid)
                  FROM events e WHERE e.id = ? AND e.session_resource_id IS NULL
            }, $run->data->{created_resource_id}, $event_id )->array : undef;
            push @errors, !$free ? 'Choose one of your occurrences'
                : !$free->[0] ? 'That occurrence already has its resource' : ();
        }
        return { stay => 1, errors => \@errors } if @errors;

        # One resource per run: the run's row is locked while this reads
        # whether it has created one, so a repeated submission finds the first.
        my $tx = $db->dbh->{AutoCommit} ? $db->begin : undef;
        my $created = $db->query( q{
            SELECT data->>'created_resource_id' FROM workflow_runs WHERE id = ? FOR UPDATE
        }, $run->id )->array->[0];
        unless ($created) {
            $created = eval {
                Registry::DAO::Resource->create( $db, {
                    name => $name,
                    kind => $f{resource_kind},
                    $finite ? ( capacity => 0 + $f{capacity}, event_id => $event_id ) : (),
                } )->id;
            } or return { stay => 1, errors => ['Could not create the resource'] };
            $run->update_data( $db, { created_resource_id => $created } );
        }
        $tx->commit if $tx;

        return { resource_choice => { mode => 'create', resource_id => $created } };
    }

    # Occurrences in this schema with no resource yet: one occurrence has at
    # most one, and a session's day is no occurrence.
    method prepare_template_data ( $db, $run, $params = {} ) {
        return {
            classes     => [ Registry::DAO::Project->find( $db, {}, { -asc => 'name' } ) ],
            occurrences => $db->query( q{
            SELECT e.id, p.name || ', ' || to_char(e.time, 'YYYY-MM-DD HH24:MI') AS label
              FROM events e JOIN projects p ON p.id = e.project_id
             WHERE NOT EXISTS (SELECT 1 FROM resources r WHERE r.event_id = e.id) AND e.session_resource_id IS NULL
             ORDER BY e.time
            } )->hashes->to_array,
        };
    }
}

1;
