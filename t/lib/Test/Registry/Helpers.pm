# ABOUTME: Test helpers for Registry workflow integration tests.
# ABOUTME: Provides process_workflow and URL helper functions for Test::Mojo-based tests.
use 5.42.0;

package Test::Registry::Helpers {
    use experimental qw(declared_refs);
    use builtin      qw(export_lexically);

    sub import(@) {
        no warnings;
        export_lexically(
            authenticate_as                  => __PACKAGE__->can('authenticate_as'),
            import_all_workflows             => __PACKAGE__->can('import_all_workflows'),
            process_workflow                 => __PACKAGE__->can('process_workflow'),
            platform_revenue_share_plan_id =>
              __PACKAGE__->can('platform_revenue_share_plan_id'),
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

    # platform_revenue_share_plan_id($dao) -- issue #268
    #
    # Returns the UUID of the platform 2% revenue-share plan so a signup leg can
    # POST it as selected_plan_id, and asserts (as a guard) that the
    # create-default-pricing-relationships migration seeded exactly one active
    # platform pricing relationship for it. Fails loudly if the migration's seed
    # is missing (e.g. a stale test-schema dump), instead of silently skipping
    # the pricing step downstream.
    sub platform_revenue_share_plan_id ($dao) {
        my $db = $dao->db;

        my $plan_row = $db->query(q{
            SELECT id FROM registry.pricing_plans
            WHERE pricing_model_type = 'percentage' AND plan_scope = 'tenant' LIMIT 1
        })->hash;
        die 'No tenant-scoped percentage plan in DB -- cannot walk pricing step'
            unless $plan_row;
        Test::More::ok($plan_row, '2% revenue-share plan present in registry.pricing_plans');

        my $plan_id = $plan_row->{id};

        # Verify the migration seeded the relationship so a misconfigured DB
        # fails loudly here, not later.
        my $rel_count = $db->query(q{
            SELECT count(*) AS n FROM registry.pricing_relationships
            WHERE provider_id = '00000000-0000-0000-0000-000000000000'
              AND pricing_plan_id = ?
        }, $plan_id)->hash->{n};
        Test::More::is($rel_count, 1, 'migration seeded exactly one platform pricing relationship for the plan');

        return $plan_id;
    }

    sub import_all_workflows ($dao) {
        require Mojo::Home;
        require YAML::XS;
        require Registry::DAO;
        require Registry::DAO::OutcomeDefinition;

        # Import outcome definitions BEFORE workflows.  copy_workflow inserts
        # workflow_steps rows with outcome_definition_id FK values that reference
        # the registry schema's outcome_definitions table.  If no definitions
        # exist when from_yaml runs the FK insert fails.  This mirrors the
        # production boot order in Registry.pm before_server_start:
        # import_schemas, then import_workflows.
        my @schema_files =
          Mojo::Home->new->child('schemas')->list->grep(qr/\.json$/)->each;
        Registry::DAO::OutcomeDefinition->import_from_file($dao, $_)
          for @schema_files;

        my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
        for my $file (@files) {
            next if YAML::XS::Load($file->slurp)->{draft};
            Registry::DAO::Workflow->from_yaml($dao, $file->slurp);
        }
    }

    # NOTE: This registers a permanent before_dispatch hook. Calling
    # authenticate_as multiple times accumulates hooks, but the guards
    # (unless session/stash already set) ensure only the first takes
    # effect per request. This is a test-only approximation -- the
    # stash hash is built manually and may drift from the production
    # user_to_stash closure in Registry.pm.
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
