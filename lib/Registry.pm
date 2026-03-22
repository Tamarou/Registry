# ABOUTME: Main Mojolicious application class for the Registry project
# ABOUTME: Defines application startup, route configuration, and authentication helpers
use 5.42.0;
use Object::Pad;
use Registry::DAO;
use Registry::Middleware::RateLimit;
use Registry::Job::AttendanceCheck;
use Registry::Job::ProcessWaitlist;
use Registry::Job::WaitlistExpiration;
use Registry::Command::schema;
use Registry::Command::template;
use Registry::Command::workflow;

class Registry :isa(Mojolicious) {
    our $VERSION = v0.001;
    use Sys::Hostname            qw( hostname );
    use YAML::XS                 qw(Load);
    use Registry::Utility::Logger;

    method startup {
        # Replace default Mojolicious logger with structured JSON logger.
        # Level defaults to the LOG_LEVEL environment variable, falling back to 'info'.
        $self->log(
            Registry::Utility::Logger->new(
                level => $ENV{LOG_LEVEL} // 'info'
            )
        );

        $self->secrets( [hostname] );

        # Configure proper UTF-8 handling
        $self->renderer->default_format('html');
        $self->renderer->encoding('UTF-8');

        # Add another namespace to load commands from
        push $self->commands->namespaces->@*, 'Registry::Command';

        # Setup Minion for background jobs
        $self->plugin('Minion' => {
            Pg => $ENV{DB_URL} || 'postgresql://localhost/registry'
        });

        # Register background jobs
        Registry::Job::AttendanceCheck->register($self);
        Registry::Job::ProcessWaitlist->register($self);
        Registry::Job::WaitlistExpiration->register($self);

        # Register CSV renderer for data exports with Text::CSV_XS for proper escaping and streaming
        $self->renderer->add_handler(csv => sub ($renderer, $c, $output, $options) {
            use Text::CSV_XS;

            my $data = $options->{csv} // [];
            my $chunk_size = $options->{chunk_size} // 1000; # Process in chunks for memory efficiency
            my $stream = $options->{stream} // 0; # Enable true streaming mode

            # Handle empty data gracefully
            unless (@$data && ref $data->[0] eq 'HASH') {
                $$output = "No data available for export\n";
                return;
            }

            # Create CSV object with proper configuration
            my $csv = Text::CSV_XS->new({
                binary => 1,
                auto_diag => 1,
                eol => "\n",
                sep_char => ',',
                quote_char => '"',
                escape_char => '"',
                always_quote => 1,
            });

            # Determine headers from first row (maintain consistent order)
            my @headers = sort keys %{$data->[0]};

            eval {
                if ($stream && @$data > $chunk_size) {
                    # For large datasets, use chunked streaming to prevent memory exhaustion
                    $csv->combine(@headers) or die "CSV error: " . $csv->error_diag;
                    $c->write_chunk($csv->string . "\n");

                    # Process data in chunks
                    for (my $i = 0; $i < @$data; $i += $chunk_size) {
                        my $end = $i + $chunk_size - 1;
                        $end = $#$data if $end > $#$data;

                        my $chunk_content = '';
                        for my $j ($i..$end) {
                            my $row = $data->[$j];
                            my @values = map {
                                my $val = $row->{$_};
                                defined $val ? $val : '';
                            } @headers;

                            $csv->combine(@values) or die "CSV error: " . $csv->error_diag;
                            $chunk_content .= $csv->string . "\n";
                        }

                        $c->write_chunk($chunk_content);
                    }

                    # Finish streaming
                    $c->write_chunk('');
                    $$output = '';
                } else {
                    # For smaller datasets, use in-memory generation
                    my $csv_content = '';

                    # Generate header line
                    $csv->combine(@headers) or die "CSV error: " . $csv->error_diag;
                    $csv_content .= $csv->string . "\n";

                    # Generate data rows
                    for my $row (@$data) {
                        my @values = map {
                            my $val = $row->{$_};
                            defined $val ? $val : '';
                        } @headers;

                        $csv->combine(@values) or die "CSV error: " . $csv->error_diag;
                        $csv_content .= $csv->string . "\n";
                    }

                    $$output = $csv_content;
                }
            };

            if ($@) {
                # Log error and provide user-friendly message
                $c->log->error("CSV export failed: $@");
                if ($stream) {
                    $c->write_chunk("Error generating CSV export: $@\n");
                    $c->write_chunk('');
                } else {
                    $$output = "Error generating CSV export: $@\n";
                }
            }
        });

        $self->helper(
            tenant => sub ($c, $explicit_tenant = undef) {
                # Determine tenant: explicit param > header > cookie > subdomain > default
                return $explicit_tenant if $explicit_tenant;

                my $header_tenant = $c->req->headers->header('X-As-Tenant');
                my $cookie_tenant = $c->req->cookie('as-tenant');
                my $subdomain_tenant = $self->_extract_tenant_from_subdomain($c);

                return $header_tenant || $cookie_tenant || $subdomain_tenant || 'registry';
            }
        );

        $self->helper(
            dao => sub ($c, $tenant = undef) {
                $tenant = $c->tenant($tenant);

                # Create new DAO for this tenant (no caching as per user preference)
                return Registry::DAO->new(
                    url => $ENV{DB_URL},
                    schema => $tenant
                );
            }
        );

        # Populate current_user stash from session on every request
        $self->hook(
            before_dispatch => sub ($c) {
                my $user_id = $c->session('user_id');
                return unless $user_id;

                try {
                    my $dao  = Registry::DAO->new( url => $ENV{DB_URL} );
                    my $user = Registry::DAO::User->find( $dao->db, { id => $user_id } );
                    $c->stash( current_user => {
                        id        => $user->id,
                        username  => $user->username,
                        name      => $user->name,
                        email     => $user->email,
                        user_type => $user->user_type,
                        # Provide a 'role' alias for backward compatibility with
                        # controllers that check $user->{role}
                        role      => $user->user_type,
                    } ) if $user;
                }
                catch ($e) {
                    $c->app->log->warn("Failed to load current_user from session: $e");
                }
            }
        );

        # Helper: require an authenticated session.
        # Redirects browsers to login; sends 401 JSON to API clients.
        # Returns true if authenticated, false (and terminates dispatch) otherwise.
        $self->helper(
            require_auth => sub ($c) {
                return 1 if $c->stash('current_user');

                # JSON / XHR clients get a 401 JSON response
                if (   $c->req->headers->header('X-Requested-With')
                    || ( $c->req->headers->accept // '' ) =~ m{application/json} )
                {
                    $c->render(
                        json   => { error => 'Authentication required' },
                        status => 401
                    );
                    return 0;
                }

                # Browser clients get redirected to the login workflow
                $c->redirect_to('/user-creation');
                return 0;
            }
        );

        # Helper: require an authenticated session AND one of the given roles.
        # Calls require_auth first, then checks user_type against allowed roles.
        # Sends 403 to wrong-role browser requests; 403 JSON to API clients.
        $self->helper(
            require_role => sub ( $c, @allowed_roles ) {
                return 0 unless $c->require_auth;

                my $user      = $c->stash('current_user');
                my $user_role = $user->{user_type} // '';

                for my $allowed (@allowed_roles) {
                    return 1 if $user_role eq $allowed;
                }

                # Wrong role - send 403
                if (   $c->req->headers->header('X-Requested-With')
                    || ( $c->req->headers->accept // '' ) =~ m{application/json} )
                {
                    $c->render(
                        json   => { error => 'Forbidden' },
                        status => 403
                    );
                }
                else {
                    $c->render( text => 'Forbidden', status => 403 );
                }
                return 0;
            }
        );

        $self->hook(
            before_server_start => sub ( $server, @ ) {
                $self->import_schemas;
                $self->import_templates;
                $self->import_workflows(); # Use defaults: schema='registry', files=undef, verbose=0
                $self->setup_recurring_jobs;
            }
        );

        # CSRF token validation for all state-changing requests.
        # Webhook endpoints use their own HMAC-based auth and are excluded.
        # Accepts token from the csrf_token form field or the X-CSRF-Token header.
        $self->hook(
            before_dispatch => sub ($c) {
                my $method = $c->req->method;

                # Only validate state-changing HTTP methods
                return unless $method eq 'POST' || $method eq 'PUT' || $method eq 'DELETE';

                # Webhook endpoints use their own authentication scheme
                return if $c->req->url->path =~ m{^/webhooks/};

                my $expected = $c->csrf_token;

                my $supplied =
                     $c->req->param('csrf_token')
                  || $c->req->headers->header('X-CSRF-Token')
                  || '';

                unless ( $supplied eq $expected ) {
                    $c->render( text => 'CSRF token validation failed', status => 403 );
                    $c->stash( exception => 'CSRF' );
                }
            }
        );

        # Set security headers on every response
        my $csp = join( '; ',
            "default-src 'self'",
            "script-src 'self' 'unsafe-inline' js.stripe.com unpkg.com cdn.jsdelivr.net",
            "style-src 'self' 'unsafe-inline'",
            "connect-src 'self' api.stripe.com",
            "frame-src js.stripe.com",
            "img-src 'self' data:",
            "font-src 'self'",
        );
        $self->hook(
            after_dispatch => sub ($c) {
                my $headers = $c->res->headers;
                $headers->header( 'X-Frame-Options'        => 'DENY' );
                $headers->header( 'X-Content-Type-Options' => 'nosniff' );
                $headers->header( 'X-XSS-Protection'       => '0' );
                $headers->header( 'Content-Security-Policy' => $csp );

                # HSTS only over HTTPS (direct TLS or via trusted proxy)
                my $forwarded_proto = $c->req->headers->header('X-Forwarded-Proto') // '';
                if ( $c->req->is_secure || $forwarded_proto eq 'https' ) {
                    $headers->header(
                        'Strict-Transport-Security' => 'max-age=31536000; includeSubDomains'
                    );
                }
            }
        );

        # Inject the CSRF hidden input into every HTML form in the rendered response.
        # This covers all templates without requiring each one to be updated individually.
        # The token value comes from the session-bound csrf_token helper.
        $self->hook(
            after_render => sub ($c, $output, $format) {
                return unless $format && $format eq 'html';
                return unless ref $output eq 'SCALAR';

                my $token = $c->csrf_token;
                my $hidden = qq{<input type="hidden" name="csrf_token" value="$token">};

                # Insert the hidden field immediately after each opening <form tag
                $$output =~ s{(<form\b[^>]*>)}{$1$hidden}gi;
            }
        );

        # Rate limiting: applied to all requests before dispatch.
        # Webhook and static-asset paths are excluded (see Registry::Middleware::RateLimit).
        # Auth endpoints (login, signup, etc.) are limited to 10 req/min per IP.
        # All other endpoints are limited to 100 req/min per IP (or authenticated user).
        my $rate_limiter = Registry::Middleware::RateLimit->new;
        $self->hook(
            before_dispatch => sub ($c) {
                $rate_limiter->before_dispatch($c);
            }
        );

        # Public school pages (no auth required)
        $self->routes->get('/school/:slug')->to('schools#show')
          ->name('show_school');

        # Health check endpoint (no auth required)
        $self->routes->get('/health')->to(cb => sub ($c) {
            # Simple health check - just verify app is responding
            $c->render(json => { status => 'ok', timestamp => time() });
        })->name('health_check');

        # Webhook routes (no auth required)
        $self->routes->post('/webhooks/stripe')->to('webhooks#stripe')
          ->name('webhook_stripe');

        # Route handling for root path - always use default workflow landing page
        $self->routes->get('/')->to('landing#root')->name('root_handler');

        my $r = $self->routes;

        # Teacher routes: requires staff or admin role (staff and admin can also access)
        my $teacher = $r->under('/teacher')->to(
            cb => sub ($c) { $c->require_role( 'staff', 'admin' ) }
        );
        $teacher->get('/')->to('teacher_dashboard#dashboard')->name('teacher_dashboard');
        $teacher->get('/attendance/:event_id')->to('teacher_dashboard#attendance')->name('teacher_attendance');
        $teacher->post('/attendance/:event_id')->to('teacher_dashboard#mark_attendance')->name('teacher_mark_attendance');

        # Parent Dashboard routes: requires parent role
        # Must be declared before workflow routes to avoid conflicts
        my $parent = $r->under('/parent')->to(
            cb => sub ($c) { $c->require_role( 'parent', 'admin', 'staff' ) }
        );
        $parent->get('/dashboard')->to('parent_dashboard#index')->name('parent_dashboard');
        $parent->get('/dashboard/upcoming_events')->to('parent_dashboard#upcoming_events')->name('parent_dashboard_upcoming_events');
        $parent->get('/dashboard/recent_attendance')->to('parent_dashboard#recent_attendance')->name('parent_dashboard_recent_attendance');
        $parent->get('/dashboard/unread_messages_count')->to('parent_dashboard#unread_messages_count')->name('parent_dashboard_unread_messages_count');
        $parent->post('/dashboard/drop_enrollment')->to('parent_dashboard#drop_enrollment')->name('parent_dashboard_drop_enrollment');
        $parent->post('/dashboard/request_transfer')->to('parent_dashboard#request_transfer')->name('parent_dashboard_request_transfer');

        # API routes for parent dashboard (also require parent/admin/staff role)
        $r->get('/api/sessions/available')->to('parent_dashboard#available_sessions')->name('api_sessions_available');

        # Admin Dashboard routes: requires admin or staff role
        # Must be declared before workflow routes to avoid conflicts
        my $admin = $r->under('/admin')->to(
            cb => sub ($c) { $c->require_role( 'admin', 'staff' ) }
        );
        $admin->get('/dashboard')->to('workflows#index' => { workflow => 'admin-dashboard' })->name('admin_dashboard');
        $admin->get('/dashboard/program_overview')->to('admin_dashboard#program_overview')->name('admin_dashboard_program_overview');
        $admin->get('/dashboard/todays_events')->to('admin_dashboard#todays_events')->name('admin_dashboard_todays_events');
        $admin->get('/dashboard/waitlist_management')->to('admin_dashboard#waitlist_management')->name('admin_dashboard_waitlist_management');
        $admin->get('/dashboard/recent_notifications')->to('admin_dashboard#recent_notifications')->name('admin_dashboard_recent_notifications');
        $admin->get('/dashboard/enrollment_trends')->to('admin_dashboard#enrollment_trends')->name('admin_dashboard_enrollment_trends');
        $admin->get('/dashboard/export')->to('admin_dashboard#export_data')->name('admin_dashboard_export');
        $admin->post('/dashboard/send_bulk_message')->to('admin_dashboard#send_bulk_message')->name('admin_dashboard_send_bulk_message');
        $admin->get('/dashboard/pending_drop_requests')->to('admin_dashboard#pending_drop_requests')->name('admin_dashboard_pending_drop_requests');
        $admin->post('/dashboard/process_drop_request')->to('workflows#start_workflow' => { workflow => 'admin-drop-approval' })->name('admin_dashboard_process_drop_request');
        $admin->get('/dashboard/pending_transfer_requests')->to('admin_dashboard#pending_transfer_requests')->name('admin_dashboard_pending_transfer_requests');
        $admin->post('/dashboard/process_transfer_request')->to('workflows#start_workflow' => { workflow => 'admin-transfer-approval' })->name('admin_dashboard_process_transfer_request');

        # Workflow routes
        my $w = $r->any("/:workflow")->to('workflows#');
        $w->get('')->to('#index')->name("workflow_index");
        $w->post('')->to('#start_workflow')->name("workflow_start");
        $w->get("/:run/:step")->to('#get_workflow_run_step')
          ->name("workflow_step");
        $w->post("/:run/:step")->to('#process_workflow_run_step')
          ->name("workflow_process_step");
        $w->post('/:run/callcc/:target')->to('#start_continuation')
          ->name("workflow_callcc");

        # Location routes
        $r->get('/locations/:slug')->to('locations#show')
          ->name('show_location');

        # Outcome definition routes
        $r->get('/outcome/definition/:id')->to('workflows#get_outcome_definition')->name('outcome.definition');
        $r->post('/outcome/validate')->to('workflows#validate_outcome')->name('outcome.validate');

        # Tenant signup validation routes
        $r->post('/tenant-signup/validate-subdomain')->to('workflows#validate_subdomain')->name('tenant_signup.validate_subdomain');

        # Message routes
        $r->get('/messages')->to('messages#index')->name('messages_index');
        $r->post('/messages')->to('messages#create')->name('messages_create');
        $r->get('/messages/:id')->to('messages#show')->name('messages_show');
        $r->post('/messages/:id/mark_read')->to('messages#mark_read')->name('messages_mark_read');
        $r->get('/messages/preview_recipients')->to('messages#preview_recipients')->name('messages_preview_recipients');
        $r->get('/messages/unread_count')->to('messages#unread_count')->name('messages_unread_count');

        # Waitlist routes
        $r->get('/waitlist/:id')->to('waitlist#show')->name('waitlist_show');
        $r->post('/waitlist/:id/accept')->to('waitlist#accept')->name('waitlist_accept');
        $r->post('/waitlist/:id/decline')->to('waitlist#decline')->name('waitlist_decline');
        $r->get('/waitlist/status')->to('waitlist#parent_status')->name('waitlist_status');

    }

    method import_workflows ($schema = 'registry', $files = undef, $verbose = 0) {
        # If no files specified, find all workflow YAML files
        my @workflow_files;
        if ($files && @$files) {
            @workflow_files = @$files;
        } else {
            @workflow_files = $self->home->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
        }

        # Delegate to DAO helper method for consistent logic
        my $dao = $self->dao($schema);
        my $output = $dao->import_workflows(\@workflow_files, $verbose);

        # Log output if not verbose (verbose mode outputs directly)
        if (!$verbose && $output) {
            for my $line (split /\n/, $output) {
                $self->log->debug($line) if $line;
            }
        }
    }

    method import_templates () {
        # Delegate to Registry::Command::template for consistent logic
        my $template_cmd = Registry::Command::template->new(app => $self);

        # Capture output and log it instead of printing to stdout
        my $output = '';
        {
            local *STDOUT;
            open STDOUT, '>', \$output;
            $template_cmd->load('registry');
        }

        # Log each imported template
        for my $line (split /\n/, $output) {
            $self->log->debug($line) if $line;
        }
    }

    method import_schemas () {
        # Delegate to Registry::Command::schema for consistent logic
        my $schema_cmd = Registry::Command::schema->new(app => $self);

        # Capture output and log it instead of printing to stdout
        my $output = '';
        {
            local *STDOUT;
            open STDOUT, '>', \$output;
            $schema_cmd->load('registry');
        }

        # Log each imported schema
        for my $line (split /\n/, $output) {
            $self->log->debug($line) if $line;
        }
    }

    method setup_recurring_jobs {
        # Schedule attendance check to run every minute
        # Only schedule if not already scheduled
        my $existing_attendance = $self->minion->jobs({
            tasks => ['attendance_check'],
            states => ['inactive', 'active']
        })->total;

        unless ($existing_attendance) {
            # Schedule to run every minute
            $self->minion->enqueue('attendance_check', [], {
                delay => 60, # Start after 1 minute
                attempts => 3,
                priority => 5
            });

            $self->log->info("Scheduled recurring attendance check job");
        }

        # Schedule waitlist expiration check to run every 5 minutes
        my $existing_expiration = $self->minion->jobs({
            tasks => ['waitlist_expiration'],
            states => ['inactive', 'active']
        })->total;

        unless ($existing_expiration) {
            # Schedule to run every 5 minutes
            $self->minion->enqueue('waitlist_expiration', [], {
                delay => 300, # Start after 5 minutes
                attempts => 3,
                priority => 6
            });

            $self->log->info("Scheduled recurring waitlist expiration job");
        }

        # Schedule waitlist processing to run every 10 minutes
        my $existing_processing = $self->minion->jobs({
            tasks => ['process_waitlist'],
            states => ['inactive', 'active']
        })->total;

        unless ($existing_processing) {
            # Schedule to run every 10 minutes
            $self->minion->enqueue('process_waitlist', [], {
                delay => 600, # Start after 10 minutes
                attempts => 3,
                priority => 6
            });

            $self->log->info("Scheduled recurring waitlist processing job");
        }
    }

    method _extract_tenant_from_subdomain ($c) {
        my $host = $c->req->headers->host || '';
        # Remove port if present
        $host =~ s/:\d+$//;

        # Don't extract tenant from IP addresses
        return if $host =~ /^\d+\.\d+\.\d+\.\d+$/;

        # Extract tenant from subdomain: tenant.example.com -> tenant
        if ($host =~ /^([^.]+)\./) {
            my $subdomain = $1;
            return $subdomain unless $subdomain eq 'www';
        }
        return;
    }
}

__END__

=pod

=encoding utf-8

=head1 NAME

Registry - Registration software for events

=head1 DESCRIPTION

This is a simple registration system for events. It is designed to be

=head1 AUTHOR

Chris Prather <chris.prather@tamarou.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2024 by Tamarou LLC.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.
