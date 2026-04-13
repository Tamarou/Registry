# ABOUTME: Test helpers for Registry workflow integration tests.
# ABOUTME: Provides process_workflow and URL helper functions for Test::Mojo-based tests.
use 5.42.0;

package Test::Registry::Helpers {
    use experimental qw(declared_refs);
    use builtin      qw(export_lexically);

    sub import(@) {
        no warnings;
        export_lexically(
            authenticate_as           => __PACKAGE__->can('authenticate_as'),
            import_all_workflows      => __PACKAGE__->can('import_all_workflows'),
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

        # Collect pre-filled hidden input values (e.g. csrf_token injected server-side)
        # so that form submissions automatically include them without callers needing
        # to know about infrastructure fields.
        my %hidden =
          $form->find('input[type="hidden"]')
          ->grep( sub ( $f = $_ ) { $f->attr('name') && defined $f->attr('value') } )
          ->map( sub ( $f  = $_ ) { $f->attr('name') => $f->attr('value') } )
          ->to_array->@*;

        my @workflows =
          $form->find('a')
          ->grep( sub ( $a = $_ ) { ($a->attr('rel') // '') =~ /\bcreate-page\b/ } )
          ->map( sub ( $a  = $_ ) { $a->attr('href') } )->to_array->@*;

        return [ $action, \@fields, \@workflows, \%hidden ];
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

    sub import_all_workflows ($dao) {
        require Mojo::Home;
        require YAML::XS;
        require Registry::DAO;
        my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
        for my $file (@files) {
            next if YAML::XS::Load($file->slurp)->{draft};
            Registry::DAO::Workflow->from_yaml($dao, $file->slurp);
        }
    }

    sub authenticate_as ($t, $user) {
        $t->get_ok('/');  # prime the session cookie
        $t->app->hook(before_dispatch => sub ($c) {
            unless ($c->session('user_id')) {
                $c->session(user_id => $user->id);
            }
            # Set current_user stash so require_role and templates
            # see the user on this request (the app's own before_dispatch
            # hook already ran and found no session).
            unless ($c->stash('current_user')) {
                $c->stash(current_user => {
                    id        => $user->id,
                    username  => $user->username,
                    name      => $user->name,
                    email     => $user->email,
                    user_type => $user->user_type,
                    role      => $user->user_type,
                });
            }
        });
    }

    sub process_workflow ( $t, $start, $data, $headers = {}, ) {
        state %seen;    # only process each sub-workflow once
        my $url = $start;
        while ($url) {
            my $form_result = get_form( $t, $url, $headers );
            unless ($form_result) {
                last; # No form found, exit gracefully
            }
            my ( $action, $fields, $workflows, $hidden ) = @$form_result;

            # Build the submission data from the user-supplied data hash, then
            # apply pre-filled hidden values (such as csrf_token) on top so that
            # infrastructure fields always arrive with the correct server-issued
            # value, even when the caller's data hash also contains those keys.
            my %submit = ( $data->%{@$fields}, %$hidden );

            for my $workflow (@$workflows) {
                next if $seen{ [ split( '/', $workflow ) ]->[-1] }++;
                __SUB__->(
                    $t,
                    submit_form( $t, $workflow, $headers, %submit ),
                    $data, $headers
                );
            }
            $url = submit_form( $t, $action, $headers, %submit );
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
