# ABOUTME: offer-publishing's first step: use an existing resource, create one in the run's schema, or cover a class.
# ABOUTME: A finite resource has a capacity and may be bound to one occurrence; an unbounded one has neither.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::CreateResource :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Project;
    use Registry::DAO::Resource;

    my $UUID = qr/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i;

    method process ( $db, $form_data, $run = undef ) {
        my %f = map { $_ => ( ref $form_data->{$_} ? '' : $form_data->{$_} // '' ) }
            qw( resource_mode resource_name resource_kind capacity event_id class_project_id );

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
        push @errors, 'Capacity must be a whole number of at least one'
            if $finite && $f{capacity} !~ /\A[1-9][0-9]*\z/;
        return { stay => 1, errors => \@errors } if @errors;

        my $resource = Registry::DAO::Resource->create( $db, {
            name => $name,
            kind => $f{resource_kind},
            $finite ? ( capacity => 0 + $f{capacity}, event_id => $f{event_id} || undef ) : (),
        } );
        return { resource_choice => { mode => 'create', resource_id => $resource->id } };
    }

    # Occurrences in this schema with no resource yet: one occurrence has at most one.
    method prepare_template_data ( $db, $run, $params = {} ) {
        return {
            classes     => [ Registry::DAO::Project->find( $db, {}, { -asc => 'name' } ) ],
            occurrences => $db->query( q{
            SELECT e.id, p.name || ', ' || to_char(e.time, 'YYYY-MM-DD HH24:MI') AS label
              FROM events e JOIN projects p ON p.id = e.project_id
             WHERE NOT EXISTS (SELECT 1 FROM resources r WHERE r.event_id = e.id)
             ORDER BY e.time
            } )->hashes->to_array,
        };
    }
}

1;
