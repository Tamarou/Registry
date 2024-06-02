use v5.38.2;
use utf8;
use experimental qw(class builtin);

class Registry::DAO::Workflow {
    field $id : param;
    field $slug : param;
    field $name : param;
    field $description : param;
    field $first_step : param;

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

    sub find ( $, $db, $filter ) {
        __PACKAGE__->new( $db->select( 'workflows', '*', $filter )->hash->%* );
    }

    sub create ( $, $db, $data ) {
        my %data =
          $db->insert( 'workflows', $data, { returning => '*' } )->hash->%*;

        # create the first step
        Registry::DAO::WorkflowStep->create(
            $db,
            {
                workflow_id => $data{id},
                slug        => $data{first_step}
            }
        );

        return __PACKAGE__->new(%data);
    }

    method latest_run ( $db, $filter = {} ) {
        my ($run) = $self->runs( $db, $filter );
        return $run;
    }

    method new_run ($db) {
        Registry::DAO::WorkflowRun->create( $db, { workflow_id => $id } );
    }

    method runs ( $db, $filter = {} ) {
        Registry::DAO::WorkflowRun->find( $db,
            { workflow_id => $id, $filter->%* } );
    }
}

class Registry::DAO::WorkflowStep {

    field $id : param;
    field $depends_on : param = undef;
    field $description : param;
    field $metadata : param = {};
    field $slug : param;
    field $template_id : param = undef;
    field $workflow_id : param;
    field $class : param;

    sub find ( $, $db, $filter ) {
        my $data = $db->select( 'workflow_steps', '*', $filter )->expand->hash;
        return unless $data;
        return $data->{class}->new( $data->%* );
    }

    sub create ( $class, $db, $data ) {
        $data->{class} //= __PACKAGE__;
        $class->new(
            $db->insert( 'workflow_steps', $data, { returning => '*' } )
              ->hash->%* );
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

class Registry::DAO::WorkflowRun {
    use Mojo::JSON qw(encode_json);

    field $id : param;
    field $user_id : param = 0;
    field $workflow_id : param;
    field $latest_step_id : param;
    field $data : param = {};
    field $created_at : param;

    sub find ( $, $db, $filter ) {
        $db->select( 'workflow_runs', '*', $filter )
          ->expand->hashes->map( sub { __PACKAGE__->new( $_->%* ) } )
          ->to_array->@*;
    }

    sub create ( $class, $db, $data ) {
        $class->new(
            $db->insert( 'workflow_runs', $data, { returning => '*' } )
              ->hash->%* );
    }

    sub find_or_create ( $class, $db, $data ) {
        return ( find( $class, $db, $data ) || create( $class, $db, $data ) );
    }

    method id()   { $id }
    method data() { $data }

    method workflow ($db) {
        Registry::DAO::Workflow->find( $db, { id => $workflow_id } );
    }

    method is_complete ($db) {
        return !$self->next_step($db);
    }

    method latest_step ($db) {
        Registry::DAO::WorkflowStep->find( $db, { id => $latest_step_id } );
    }

    method process ( $db, $step, $new_data = {} ) {
        unless ( $step isa Registry::DAO::WorkflowStep ) {
            $step = Registry::DAO::WorkflowStep->find( $db, $step );
        }
        $data->{ $step->slug } = $step->process( $db, $new_data );
        ( $latest_step_id, $data ) = $db->update(
            'workflow_runs',
            {
                latest_step_id => $step->id,
                data           => encode_json($data),
            },
            { id        => $id },
            { returning => [qw(latest_step_id data)] }
        )->expand->hash->@{qw(latest_step_id data)};
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
}
