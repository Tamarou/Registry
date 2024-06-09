use v5.38.2;
use utf8;
use Object::Pad;

use Registry::DAO::Object;

class Registry::DAO::Workflow : isa(Registry::DAO::Object) {
    field $id : param;
    field $slug : param;
    field $name : param;
    field $description : param;
    field $first_step : param;

    use constant table => 'registry.workflows';

    sub create ( $class, $db, $data ) {
        my %data =
          $db->insert( $class->table, $data, { returning => '*' } )->hash->%*;

        # create the first step
        Registry::DAO::WorkflowStep->create(
            $db,
            {
                workflow_id => $data{id},
                slug        => $data{first_step}
            }
        );
        return $class->new(%data);
    }

    method id   { $id }
    method slug { $slug }
    method name { $name }

    method first_step ($db) {
        Registry::DAO::WorkflowStep->find( $db,
            { slug => $first_step, workflow_id => $id } );
    }

    method get_step ( $db, $filter ) {
        Registry::DAO::WorkflowStep->find( $db,
            { workflow_id => $id, $filter->%* } );
    }

    method last_step ($db) {
        my $step = $self->first_step($db);
        while ( my $next = $step->next_step($db) ) {
            $step = $next;
        }
        return $step;
    }

    method add_step ( $db, $data ) {
        my $last = $self->last_step($db);
        Registry::DAO::WorkflowStep->create( $db,
            { $data->%*, workflow_id => $id, depends_on => $last->id } );
    }

    method latest_run ( $db, $filter = {} ) {
        my ($run) = $self->runs( $db, $filter );
        return $run;
    }

    method new_run ( $db, $config //= {} ) {
        $config->{workflow_id} //= $id;
        Registry::DAO::WorkflowRun->create( $db, $config );
    }

    method runs ( $db, $filter = {} ) {
        my @runs = Registry::DAO::WorkflowRun->find( $db,
            { workflow_id => $id, $filter->%* } );
        return @runs;
    }
}

class Registry::DAO::WorkflowStep : isa(Registry::DAO::Object) {
    field $id : param;
    field $depends_on : param = undef;
    field $description : param;
    field $metadata : param = {};
    field $slug : param;
    field $template_id : param = undef;
    field $workflow_id : param;
    field $class : param;

    use constant table => 'registry.workflow_steps';

    # we store the subclass name in the database
    # so we need inflate the correct one
    sub find ( $class, $db, $filter, $order = { -desc => 'created_at' } ) {
        my $data =
          $db->select( $class->table, '*', $filter, $order )->expand->hash;
        return unless $data;
        return $data->{class}->new( $data->%* );
    }

    sub create ( $class, $db, $data ) {
        $data->{class} //= $class;
        $class->SUPER::create( $db, $data );
    }

    method id          { $id }
    method slug        { $slug }
    method template_id { $template_id }
    method workflow_id { $workflow_id }

    method next_step ($db) {
        Registry::DAO::WorkflowStep->find( $db, { depends_on => $id } );
    }

    method template ($db) {
        Registry::DAO::Template->find( $db, { id => $template_id } );
    }

    method workflow ($db) {
        Registry::DAO::Workflow->find( $db, { id => $workflow_id } );
    }

    method process ( $db, $data ) { $data }
}

class Registry::DAO::WorkflowRun : isa(Registry::DAO::Object) {
    use Mojo::JSON qw(encode_json);
    use Carp       qw( croak );

    field $id : param      = 0;
    field $user_id : param = 0;
    field $workflow_id : param;
    field $latest_step_id : param  = undef;
    field $continuation_id : param = undef;
    field $data : param //=
      {};    # might be null, we want it to always be an empty hash
    field $created_at : param;

    use constant table => 'registry.workflow_runs';

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

    method next_step ($db) {
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
