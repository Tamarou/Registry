use 5.40.2;

package Test::Registry::Helpers {
    use experimental qw(builtin declared_refs);
    use builtin      qw(export_lexically);

    sub import(@) {
        no warnings;
        export_lexically(
            process_workflow          => __PACKAGE__->can('process_workflow'),
            workflow_process_step_url =>
              __PACKAGE__->can('workflow_process_step_url'),
            workflow_run_step_url => __PACKAGE__->can('workflow_run_step_url'),
            workflow_start_url    => __PACKAGE__->can('workflow_start_url'),
            workflow_url          => __PACKAGE__->can('workflow_url'),
        );
    }

    my sub get_form ( $t, $url, $headers ) {
        my $form = $t->get_ok( $url, $headers )->status_is(200)
          ->tx->res->dom->at('form');
        return unless $form;

        my $action = $form->attr('action') || $form->attr('hx-post');
        return unless $action;

        my @fields =
          $form->find('input')
          ->grep( sub ( $field = $_ ) { $field->attr('name') } )
          ->map( sub ( $f      = $_ ) { $f->attr('name') } )->to_array->@*;
        my @workflows =
          $form->find('a')
          ->grep( sub ( $a = $_ ) { ($a->attr('rel') // '') =~ /\bcreate-page\b/ } )
          ->map( sub ( $a  = $_ ) { $a->attr('href') } )->to_array->@*;

        return [ $action, \@fields, \@workflows ];
    }

    my sub submit_form ( $t, $url, $headers, %data ) {
        my $req = $t->post_ok( $url, $headers, form => \%data );
        if ( $req->tx->res->code == 302 ) {
            return $req->status_is(302)->tx->res->headers->location;
        }
        if ( $req->tx->res->code == 201 ) {
            $req->status_is(201);
            return;
        }
        else {
            die "Unexpected response code: " . $req->tx->res->code;
        }
    }

    sub process_workflow ( $t, $start, $data, $headers = {}, ) {
        state %seen;    # only process each sub-workflow once
        my $url = $start;
        while ($url) {
            my $form_result = get_form( $t, $url, $headers );
            unless ($form_result) {
                last; # No form found, exit gracefully
            }
            my ( $action, $fields, $workflows ) = @$form_result;
            for my $workflow (@$workflows) {
                next if $seen{ [ split( '/', $workflow ) ]->[-1] }++;
                __SUB__->(
                    $t,
                    submit_form( $t, $workflow, $headers, $data->%{@$fields} ),
                    $data, $headers
                );
            }
            $url = submit_form( $t, $action, $headers, $data->%{@$fields} );
        }
    }

    sub workflow_url ($workflow) {
        return sprintf '/%s', $workflow->slug;
    }

    sub workflow_start_url ( $workflow, $step ) {
        return sprintf '/%s/%s', $workflow->slug, $step->slug;
    }

    sub workflow_run_step_url ( $workflow, $run, $step ) {
        return sprintf '/%s/%s/%s', $workflow->slug, $run->id, $step->slug;
    }

    sub workflow_process_step_url ( $workflow, $run, $step ) {
        return sprintf '/%s/%s/%s', $workflow->slug, $run->id, $step->slug;
    }

}
