use v5.34.0;
use utf8;
use Object::Pad;

# Core workflow processor
class Registry::WorkflowProcessor {
    field $dao :param;

    method new_run ( $workflow, $data //= {} ) {
        my $run  = $workflow->new_run($dao);
        my $step = $workflow->first_step($dao);
        $run->process( $dao, $step, $data );
        return $run;
    }

    method start_continuation( $run, $new_workflow ) {
        return $new_workflow->new_run( $dao, { continuation_id => $run->id } );
    }

    method get_workflow_step($run) { $run->next_step($dao) }

    method process_workflow_run_step( $run, $step, $data ) {
        return 1 if $run->completed($dao);

        $run->process( $dao, $step, $data );

        return $run->next_step($dao) unless $run->completed($dao);

        if ( $run->has_continuation ) {
            my $next_run = $run->continuation($dao);
            my $workflow = $next_run->workflow($dao);
            my $step     = $next_run->next_step($dao);
            return ( $step, $next_run );
        }

        return 1;
    }

}
