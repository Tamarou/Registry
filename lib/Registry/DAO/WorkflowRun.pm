use 5.40.2;
use Object::Pad;

class Registry::DAO::WorkflowRun :isa(Registry::DAO::Object) {
    use Mojo::JSON qw(encode_json);
    use Carp       qw( croak );

    field $id :param      = 0;
    field $user_id :param = 0;
    field $workflow_id :param;
    field $latest_step_id :param  = undef;
    field $continuation_id :param = undef;

    # This is our reference implementation for JSONB handling
    field $data :param //= {};
    field $created_at :param;

    sub table { 'workflow_runs' }

    method id()   { $id }
    method data() { $data }

    method workflow ($db) {
        Registry::DAO::Workflow->find( $db, { id => $workflow_id } );
    }

    method completed ($db) {
        my ($workflow) = $self->workflow($db);
        $self->latest_step($db)->slug eq $workflow->last_step($db)->slug;
    }

    method latest_step ($db) {
        Registry::DAO::WorkflowStep->find( $db, { id => $latest_step_id } );
    }

    method update_data ( $db, $new_data ||= {} ) {
        croak "new data must be a hashref" unless ref $new_data eq 'HASH';
        $db = $db->db if $db isa Registry::DAO;
        $data = $db->update(
            $self->table,
            { data      => encode_json( { $data->%*, $new_data->%* } ) },
            { id        => $id },
            { returning => ['data'] }
        )->expand->hash->{data};
    }

    method process ( $db, $step, $new_data = {} ) {
        unless ( $step isa Registry::DAO::WorkflowStep ) {
            $step = Registry::DAO::WorkflowStep->find( $db, $step );
        }

        # TODO we really should inline these two calls into a single query
        $self->update_data( $db, $step->process( $db, $new_data ) );
        ($latest_step_id) = $db->update(
            $self->table,
            { latest_step_id => $step->id },
            { id             => $id },
            { returning      => [qw(latest_step_id)] }
        )->expand->hash->@{qw(latest_step_id)};

        return $data;
    }

    method first_step ($db) {
        return $self->workflow($db)->first_step($db) unless $latest_step_id;
        Registry::DAO::WorkflowStep->find(
            $db,
            {
                workflow_id => $workflow_id,
                depends_on  => $latest_step_id,
            }
        ) // $self->workflow($db)->first_step($db);
    }

    method next_step ($db) {
        return $self->first_step($db) unless $latest_step_id;
        Registry::DAO::WorkflowStep->find(
            $db,
            {
                workflow_id => $workflow_id,
                depends_on  => $latest_step_id,
            }
        );
    }

    method has_continuation { defined $continuation_id }

    method continuation ($db) {
        return unless $continuation_id;
        Registry::DAO::WorkflowRun->find( $db, { id => $continuation_id } );
    }
}