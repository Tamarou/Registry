# ABOUTME: Test helpers for Registry workflow integration tests.
# ABOUTME: Provides process_workflow and URL helper functions for Test::Mojo-based tests.
use 5.42.0;

package Test::Registry::Helpers {
    use experimental qw(declared_refs);
    use builtin      qw(export_lexically);
    use Time::Local  qw(timelocal_posix);

    sub import(@) {
        no warnings;
        export_lexically(
            authenticate_as      => __PACKAGE__->can('authenticate_as'),
            birth_date_for_age   => __PACKAGE__->can('birth_date_for_age'),
            days_from_now        => __PACKAGE__->can('days_from_now'),
            import_all_workflows             => __PACKAGE__->can('import_all_workflows'),
            join_tenant          => __PACKAGE__->can('join_tenant'),
            process_workflow                 => __PACKAGE__->can('process_workflow'),
            platform_solo_offer_version_id =>
              __PACKAGE__->can('platform_solo_offer_version_id'),
            publish_offer        => __PACKAGE__->can('publish_offer'),
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
          $form->find('input, select')
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

    # platform_solo_offer_version_id($dao)
    #
    # The platform tenant's current published Solo offer version: what signup
    # grants a tenant. Dies when there is none, so a stale test-schema dump
    # fails here rather than somewhere downstream.
    sub platform_solo_offer_version_id ($dao) {
        my $db  = $dao isa Registry::DAO ? $dao->db : $dao;
        my $row = $db->query(q{
            SELECT v.id FROM registry.offer_versions v
              JOIN registry.offers o ON o.id = v.offer_id
             WHERE o.name = 'Solo' AND v.published_at IS NOT NULL AND v.superseded_at IS NULL
        })->array;
        die "No current published Solo offer version in registry\n" unless $row;
        return $row->[0];
    }

    # The neutral answer to every offer-publishing step step 4 has or will
    # add. A step the stored workflow does not have is simply never walked.
    my %OFFER_STEP_DEFAULTS = (
        'resource'                    => { resource_mode       => 'existing' },
        'one-time-payment'            => { one_time            => 'offered' },
        'percentage-of-sales-payment' => { percentage_of_sales => 'declined' },
        'refund-policy'               => { refund              => 'none' },
        'change-policy'               => { change              => 'none' },
        'use-policy'                  => { use                 => 'none' },
        'expiry-policy'               => { expiry              => 'never' },
        'publish'                     => { action              => 'publish' },
    );

    # publish_offer($dao, $tenant_slug, $admin_user, \%terms) -> OfferVersion
    #
    # The only way a test publishes an offer: runs offer-publishing in
    # $tenant_slug's schema as $admin_user through Registry::WorkflowProcessor,
    # walking whatever steps the stored workflow has. Each step is submitted
    # every step's neutral default, then $terms' top-level fields (so
    # `refund => undef` withdraws the refund choice from whichever step asks
    # for it), then $terms->{<step slug>}. Dies naming the step that refuses.
    sub publish_offer ( $dao, $tenant_slug, $admin_user, $terms ) {
        require Registry::DAO::OfferVersion;
        require Registry::Utility::WorkflowProcessor;
        my $tenant_dao = $dao->connect_schema($tenant_slug);
        my $db         = $tenant_dao->db;
        my $workflow   = $tenant_dao->find( Workflow => { slug => 'offer-publishing' } )
          or die "publish_offer: no offer-publishing workflow in '$tenant_slug'\n";
        my $processor = Registry::WorkflowProcessor->new( dao => $tenant_dao );
        my $run = $processor->new_run( $workflow,
            { user => { id => $admin_user->id, name => $admin_user->name } } );

        my %fields = ( map( { %$_ } values %OFFER_STEP_DEFAULTS ),
            map { $_ => $terms->{$_} } grep { !ref $terms->{$_} } keys %$terms );
        for ( my $step = $workflow->first_step($db) ; $step ; $step = $step->next_step($db) ) {
            my $result = $run->process( $db, $step, { %fields, ( $terms->{ $step->slug } // {} )->%* } );
            die sprintf "publish_offer: %s refused: %s\n", $step->slug, join '; ', $result->{errors}->@*
              if ref $result eq 'HASH' && $result->{errors};
            my $published = $run->data->{published_offer_version_id} or next;
            return Registry::DAO::OfferVersion->find( $db, { id => $published } );
        }
        die "publish_offer: the walk ended without publishing\n";
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

    # Make $user a member of the tenant $slug -- the platform tenant, whose
    # host an unpinned request uses, by default -- with $role, which
    # Tenant::add_user defaults to the user's user_type. Authority in a tenant
    # is the membership's role (ADR 005, ruling 4), so a fixture acting as an
    # admin or staff member somewhere has to be one there. Idempotent: an
    # existing membership is left as it is.
    sub join_tenant ( $db, $user, $role = undef, $slug = 'registry' ) {
        require Registry::DAO::Tenant;
        $db = $db->db if $db isa Registry::DAO;
        my $tenant = Registry::DAO::Tenant->find( $db, { slug => $slug } )
          or die "join_tenant: no tenant '$slug'";
        return if $db->select( 'registry.tenant_users', 'user_id',
            { tenant_id => $tenant->id, user_id => $user->id } )->rows;
        $tenant->add_user( $db, $user, 0, $role );
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
                my $stashed = {
                    id        => $user->id,
                    username  => $user->username,
                    name      => $user->name,
                    email     => $user->email,
                    user_type => $user->user_type,
                };
                $c->stash(current_user => $stashed);
                # As production fills it: the role in this request's tenant,
                # from the membership, never the global user_type.
                $stashed->{role} = $c->tenant_role // '';
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

    # Fixture dates must be derived from the day the suite runs. A hardcoded
    # date tests a real path when it is written and an impossible one once it
    # expires, because listing, selection and eligibility all filter on
    # CURRENT_DATE. Nothing fails when it crosses over.
    #
    # The offset is applied to noon rather than to the current moment, so a
    # daylight-saving shift cannot move the result onto the adjacent day.
    sub days_from_now ( $days, $now = time() ) {
        my ( $year, $month, $day ) = ( localtime $now )[ 5, 4, 3 ];
        my $noon = timelocal_posix( 0, 0, 12, $day, $month, $year );
        my @then = localtime( $noon + $days * 86_400 );

        return sprintf '%04d-%02d-%02d', $then[5] + 1900, $then[4] + 1, $then[3];
    }

    # A birth date for a child who is exactly $years old on $now. Six months
    # back from the current month puts the birthday half a year away, so the
    # child's age cannot change while the suite runs; day 15 exists in every
    # month.
    sub birth_date_for_age ( $years, $now = time() ) {
        my ( $year, $month ) = ( localtime $now )[ 5, 4 ];
        $year  += 1900;
        $month += 1;

        $month -= 6;
        if ( $month < 1 ) { $month += 12; $year-- }

        return sprintf '%04d-%02d-15', $year - $years, $month;
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
