use 5.42.0;
use Object::Pad;

class Registry::DAO::WorkflowRun :isa(Registry::DAO::Object) {
    use Mojo::JSON qw(encode_json);
    use Carp       qw( croak );

    field $id :param      = 0;
    field $user_id :param = 0;
    field $workflow_id :param :reader;
    field $latest_step_id :param  = undef;
    field $continuation_id :param :reader = undef;

    # This is our reference implementation for JSONB handling
    field $data :param //= {};
    field $created_at :param;

    sub table { 'workflow_runs' }

    sub create ( $class, $db, $data ) {
        # Handle JSON fields like data
        for my $field (qw(data)) {
            next unless exists $data->{$field};
            $data->{$field} = { -json => $data->{$field} };
        }
        
        $class->SUPER::create( $db, $data );
    }

    method id()   { $id }
    method data() { 
        # Handle JSON parsing - data might be a JSON string from database
        if (defined $data && !ref $data) {
            # It's a JSON string, parse it
            use Mojo::JSON qw(decode_json);
            return decode_json($data);
        }
        return $data || {};
    }

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

        # Atomic merge at the database level using PostgreSQL jsonb concatenation.
        # This avoids the read-modify-write race where two concurrent requests
        # could each read the same initial state, merge independently, and the
        # second write would overwrite the first merge.
        my $result = $db->query(
            'UPDATE workflow_runs SET data = COALESCE(data, \'{}\'::jsonb) || ?::jsonb WHERE id = ? RETURNING data',
            encode_json($new_data), $id
        )->expand->hash;

        croak "WorkflowRun id=$id not found during update_data" unless $result;

        # Update the in-memory field with the authoritative merged result
        $data = $result->{data};
    }

    # Keys returned by workflow steps that are control-flow signals, not
    # persistent domain data. These are stripped before merging into the
    # run's JSONB data column to prevent transient metadata from polluting
    # the workflow state.
    my @TRANSIENT_KEYS = qw(
        next_step errors data _validation_errors
        retry_count retry_delay retry_exceeded should_retry
    );

    method process ( $db, $step, $new_data = {} ) {
        unless ( $step isa Registry::DAO::WorkflowStep ) {
            $step = Registry::DAO::WorkflowStep->find( $db, { slug => $step } );
        }

        $db = $db->db if $db isa Registry::DAO;

        my $step_result = $step->process( $db, $new_data );

        # Don't persist validation errors or advance the step pointer on
        # failure. The controller inspects these keys and redirects; the
        # user retries the same step.
        if ($step_result->{_validation_errors} || $step_result->{errors}) {
            return $step_result;
        }

        # Strip transient control-flow keys so only domain data is persisted.
        my %to_persist = %$step_result;
        delete @to_persist{@TRANSIENT_KEYS};

        # Atomic merge of step data + advance latest_step_id in a single query.
        # Avoids the race where a crash between two separate UPDATEs could leave
        # data updated but latest_step_id stale.
        my $result = $db->query(
            'UPDATE workflow_runs SET data = COALESCE(data, \'{}\'::jsonb) || ?::jsonb, latest_step_id = ? WHERE id = ? RETURNING data, latest_step_id',
            encode_json(\%to_persist), $step->id, $id
        )->expand->hash;

        croak "WorkflowRun id=$id not found during process" unless $result;

        $data = $result->{data};
        $latest_step_id = $result->{latest_step_id};

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

    method save($db) {
        return $self->update($db, {
            data => $data,
            latest_step_id => $latest_step_id
        });
    }
}