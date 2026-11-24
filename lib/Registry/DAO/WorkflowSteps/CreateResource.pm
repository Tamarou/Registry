# ABOUTME: offer-publishing's first step: use an existing resource or create one in the run's own schema.
# ABOUTME: A finite resource has a capacity and may be bound to one occurrence; an unbounded one has neither.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::CreateResource :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Resource;

    method process ( $db, $form_data, $run = undef ) {
        my %f = map { $_ => ( ref $form_data->{$_} ? '' : $form_data->{$_} // '' ) }
            qw( resource_mode resource_name resource_kind capacity event_id );

        return { resource_choice => { mode => 'existing' } } if $f{resource_mode} eq 'existing';
        # Also what a run's start, which submits only the seeded user, gets.
        return { stay => 1, errors => ['Choose an existing resource or create one'] }
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
        return { occurrences => $db->query( q{
            SELECT e.id, p.name || ', ' || to_char(e.time, 'YYYY-MM-DD HH24:MI') AS label
              FROM events e JOIN projects p ON p.id = e.project_id
             WHERE NOT EXISTS (SELECT 1 FROM resources r WHERE r.event_id = e.id)
             ORDER BY e.time
        } )->hashes->to_array };
    }
}

1;
