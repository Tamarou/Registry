# ABOUTME: Main Mojolicious application class for the Registry project
# ABOUTME: Defines application startup, route configuration, and authentication helpers
use 5.42.0;
use Object::Pad;
use Registry::DAO;
use Registry::Middleware::RateLimit;
use Registry::Job::AttendanceCheck;
use Registry::Job::DomainVerification;
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

        if ($ENV{MOJO_SECRET}) {
            $self->secrets( [$ENV{MOJO_SECRET}] );
        } elsif ($self->mode eq 'development') {
            $self->log->warn("MOJO_SECRET not set -- using hostname for development only");
            $self->secrets( [hostname] );
        } else {
            die "MOJO_SECRET environment variable is required in production";
        }

        # Static asset URL prefix. When STATIC_URL is set, CSS/JS/images are
        # served from an external static site (e.g. Render static service or CDN).
        # When unset, assets are served from the app itself (same-origin).
        my $static_url = $ENV{STATIC_URL} // '';
        $self->helper( static_url => sub { $static_url } );

        # Configure proper UTF-8 handling
        $self->renderer->default_format('html');
        $self->renderer->encoding('UTF-8');

        # Add another namespace to load commands from
        push $self->commands->namespaces->@*, 'Registry::Command';

        # Setup Minion for background jobs
        $self->plugin('Minion' => {
            Pg => $ENV{DB_URL} || 'postgresql://localhost/registry'
        });

        # HTMX plugin provides is_htmx_request, htmx->res->push_url, etc.
        $self->plugin('Mojolicious::Plugin::HTMX');

        # DB-stored templates as first-class renderer citizens
        $self->plugin('Mojolicious::Plugin::DBTemplates');

        # Wrap the layout helper so templates' `% layout 'foo'` becomes a
        # no-op when the controller sets _htmx_fragment in the stash.
        my $original_layout = $self->renderer->helpers->{layout};
        $self->renderer->helpers->{layout} = sub ($c, @args) {
            return if $c->stash('_htmx_fragment');
            $original_layout->($c, @args);
        };

        # Register background jobs
        Registry::Job::AttendanceCheck->register($self);
        Registry::Job::DomainVerification->register($self);
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
                # Determine tenant: explicit param > header/cookie (authed only) > subdomain > default
                # X-As-Tenant and as-tenant cookie are restricted to authenticated
                # users to prevent unauthenticated cross-tenant access.
                # Check both session auth and bearer token (API key) auth.
                my $header_tenant;
                if ($c->session('user_id') || $c->stash('current_user')) {
                    $header_tenant = $c->req->headers->header('X-As-Tenant')
                                  || $c->req->cookie('as-tenant');
                }

                my $raw = $explicit_tenant
                    || $header_tenant
                    || $self->_extract_tenant_from_subdomain($c);

                # Custom domain lookup: if no tenant found via subdomain/header/cookie,
                # check whether the Host header matches a verified custom domain.
                # Uses $c->dao('registry')->db so the lookup goes through the existing
                # helper (respecting $ENV{DB_URL}) rather than a bare Registry::DAO->new.
                # The per-request query is an accepted trade-off; the domain index makes
                # it sub-millisecond.
                unless ($raw) {
                    my $host = lc($c->req->url->to_abs->host // '');
                    if ($host && $host !~ /\blocalhost\b/) {
                        try {
                            require Registry::DAO::TenantDomain;
                            # Keep the DAO object alive while using its db handle.
                            # Without this, the Mojo::Pg object is garbage collected,
                            # invalidating the database connection.
                            my $registry_dao = $c->dao('registry');
                            my $db = $registry_dao->db;
                            my $td = Registry::DAO::TenantDomain->find_by_domain($db, $host);
                            if ($td && $td->status eq 'verified') {
                                require Registry::DAO::Tenant;
                                my $tenant = Registry::DAO::Tenant->find($db, { id => $td->tenant_id });
                                $raw = $tenant->slug if $tenant;
                            }
                        }
                        catch ($e) {
                            $c->app->log->warn("Custom domain lookup failed: $e");
                        }
                    }
                }

                $raw //= 'registry';

                # Sanitize: tenant slugs must be safe SQL identifiers
                return 'registry' unless $raw =~ /\A[a-z][a-z0-9_]{0,62}\z/;

                return $raw;
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

        # Render.com Custom Domains API client, injected as a helper so tests
        # can replace it with a mock without touching production code.
        $self->helper(
            render_service => sub {
                require Registry::Service::Render;
                state $svc = Registry::Service::Render->new(
                    api_key    => $ENV{RENDER_API_KEY}    // '',
                    service_id => $ENV{RENDER_SERVICE_ID} // '',
                );
                return $svc;
            }
        );

        # Populate current_user stash from session or bearer token on every request
        my $user_to_stash = sub ($user, %extra) {
            return {
                id        => $user->id,
                username  => $user->username,
                name      => $user->name,
                email     => $user->email,
                user_type => $user->user_type,
                # Provide a 'role' alias for backward compatibility with
                # controllers that check $user->{role}
                role      => $user->user_type,
                %extra,
            };
        };

        $self->hook(
            before_dispatch => sub ($c) {
                # 0. HTTPS redirect in production
                if ($self->mode eq 'production') {
                    my $proto = $c->req->headers->header('X-Forwarded-Proto') // '';
                    if ($proto eq 'http') {
                        my $url = $c->req->url->to_abs;
                        $url->scheme('https');
                        $c->redirect_to($url);
                        return;
                    }
                }

                # 1. Bearer token auth (API keys)
                my $auth_header = $c->req->headers->authorization // '';
                if ($auth_header =~ /^Bearer\s+(.+)$/i) {
                    my $token = $1;
                    try {
                        require Registry::DAO::ApiKey;
                        my $dao = $c->dao;
                        my $api_key = Registry::DAO::ApiKey->find_by_plaintext($dao->db, $token);

                        if ($api_key && !$api_key->is_expired) {
                            my $user = Registry::DAO::User->find($dao->db, { id => $api_key->user_id });
                            if ($user) {
                                $api_key->touch($dao->db);
                                $c->stash( current_user => $user_to_stash->($user, api_key => $api_key) );
                                return;  # Skip session check
                            }
                        }

                        # Invalid or expired key -- always reject when a Bearer
                        # token was explicitly presented, regardless of client type.
                        if (   $c->req->headers->header('X-Requested-With')
                            || ( $c->req->headers->accept // '' ) =~ m{application/json} )
                        {
                            $c->render(
                                json   => { error => 'Invalid or expired API key' },
                                status => 401
                            );
                        }
                        else {
                            $c->render(
                                text   => 'Invalid or expired API key',
                                status => 401
                            );
                        }
                        return;
                    }
                    catch ($e) {
                        $c->app->log->warn("Bearer token auth failed: $e");
                        # DB or parsing error with an explicit Bearer token --
                        # do not fall through to session auth.
                        $c->render(text => 'Authentication error', status => 500);
                        return;
                    }
                }

                # 2. Session cookie auth (existing logic)
                my $user_id = $c->session('user_id');
                return unless $user_id;

                try {
                    my $dao  = $c->dao;
                    my $user = Registry::DAO::User->find( $dao->db, { id => $user_id } );
                    $c->stash( current_user => $user_to_stash->($user) ) if $user;
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
                $c->redirect_to('/auth/login');
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

        # DB-first template resolution handled in Controller::render.

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

                # Bearer-token-authenticated requests use key-based auth, not sessions
                my $cu = $c->stash('current_user');
                return if $cu && $cu->{api_key};

                # WebAuthn endpoints have built-in origin validation via the protocol
                return if $c->req->url->path =~ m{^/auth/webauthn/};

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
        # Build CSP with optional static asset origin
        my $static_origin = $static_url ? " $static_url" : '';
        my $csp = join( '; ',
            "default-src 'self'$static_origin",
            "script-src 'self' 'unsafe-inline' js.stripe.com unpkg.com cdn.jsdelivr.net$static_origin",
            "style-src 'self' 'unsafe-inline' fonts.googleapis.com$static_origin",
            "connect-src 'self' api.stripe.com",
            "frame-src js.stripe.com",
            "img-src 'self' data:$static_origin",
            "font-src 'self' fonts.googleapis.com fonts.gstatic.com$static_origin",
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

        # Database-first template resolution: check the tenant's schema for a
        # customized template before falling back to the filesystem default.
        # This is the mechanism that enables the workflow marketplace -- tenants
        # can customize templates without modifying platform files.
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

        # Canonical domain redirect: if the tenant has a canonical domain and the
        # request arrived on a different host, redirect with 301. The per-request
        # DB query is an accepted trade-off (see spec); the index keeps it fast.
        $self->hook(
            before_dispatch => sub ($c) {
                my $path = $c->req->url->path;

                # Skip webhook, health check, and static asset paths
                return if $path =~ m{^/(webhooks|health|assets)};

                my $host = lc($c->req->url->to_abs->host // '');
                return unless $host;

                # Resolve tenant and check for canonical domain
                my $tenant_slug = $c->tenant;
                return if $tenant_slug eq 'registry';

                try {
                    # Look up the tenant record in the registry schema (tenants table lives there)
                    my $dao = $c->dao('registry');
                    my $tenant = Registry::DAO::Tenant->find($dao->db, { slug => $tenant_slug });
                    return unless $tenant && $tenant->canonical_domain;

                    my $canonical = lc($tenant->canonical_domain);

                    # Skip if already on the canonical domain (prevents redirect loops)
                    return if $host eq $canonical;

                    # Build redirect URL preserving path and query
                    my $redirect = $c->req->url->to_abs->clone;
                    $redirect->host($canonical);
                    $c->res->headers->location($redirect->to_string);
                    $c->rendered(301);
                }
                catch ($e) {
                    $c->app->log->warn("Canonical domain redirect failed: $e");
                }
            }
        );

        # Legacy school route removed -- storefront at / replaces it

        # Health check endpoint (no auth required)
        $self->routes->get('/health')->to(cb => sub ($c) {
            # Simple health check - just verify app is responding
            $c->render(json => { status => 'ok', timestamp => time() });
        })->name('health_check');

        # Webhook routes (no auth required)
        $self->routes->post('/webhooks/stripe')->to('webhooks#stripe')
          ->name('webhook_stripe');

        # Root route dispatches to the tenant-storefront workflow
        $self->routes->get('/')->to('workflows#index', workflow => 'tenant-storefront')->name('root_handler');
        $self->routes->post('/')->to('workflows#start_workflow', workflow => 'tenant-storefront');

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

        $admin->get('/templates')->to('workflows#index', workflow => 'template-editor')->name('admin_templates');
        $admin->post('/templates')->to('workflows#start_workflow', workflow => 'template-editor');

        # Domain management routes: admin-only (staff cannot access)
        # This is a separate under() group from $admin so that staff cannot reach
        # these routes even though staff can reach other /admin/* routes.
        my $admin_only = $r->under('/admin')->to(
            cb => sub ($c) { $c->require_role('admin') }
        );
        $admin_only->get('/domains')->to('TenantDomains#index')->name('admin_domains');
        $admin_only->post('/domains')->to('TenantDomains#add')->name('admin_domains_add');
        $admin_only->post('/domains/:id/verify')->to('TenantDomains#verify')->name('admin_domains_verify');
        $admin_only->post('/domains/:id/primary')->to('TenantDomains#set_primary')->name('admin_domains_primary');
        $admin_only->post('/domains/:id/remove')->to('TenantDomains#remove')->name('admin_domains_remove');

        # Auth routes (unprotected -- no require_auth)
        my $auth = $r->under('/auth');
        $auth->get('/login')->to('Auth#login');
        $auth->post('/magic/request')->to('Auth#request_magic_link');
        $auth->get('/magic/poll/:token_hash')->to('Auth#magic_link_status');
        $auth->post('/magic/poll/:token_hash/complete')->to('Auth#magic_link_complete_by_hash');
        $auth->get('/magic/:token')->to('Auth#verify_magic_link');
        $auth->post('/magic/:token/complete')->to('Auth#complete_magic_link');
        $auth->post('/logout')->to('Auth#logout');
        $auth->get('/verify-email/:token')->to('Auth#verify_email');
        $auth->post('/webauthn/register/begin')->to('Auth#webauthn_register_begin');
        $auth->post('/webauthn/register/complete')->to('Auth#webauthn_register_complete');
        $auth->post('/webauthn/auth/begin')->to('Auth#webauthn_auth_begin');
        $auth->post('/webauthn/auth/complete')->to('Auth#webauthn_auth_complete');
        $auth->post('/api-keys')->to('Auth#create_api_key');
        $auth->get('/api-keys')->to('Auth#list_api_keys');

        # Location routes
        $r->get('/locations/:slug')->to('locations#show')
          ->name('show_location');

        # Outcome definition routes
        $r->get('/outcome/definition/:id')->to('workflows#get_outcome_definition')->name('outcome.definition');
        $r->post('/outcome/validate')->to('workflows#validate_outcome')->name('outcome.validate');

        # Tenant signup validation routes
        $r->post('/tenant-signup/validate-subdomain')->to('workflows#validate_subdomain')->name('tenant_signup.validate_subdomain');

        # Message routes -- must be declared before the /:workflow catch-all
        $r->get('/messages')->to('messages#index')->name('messages_index');
        $r->post('/messages')->to('messages#create')->name('messages_create');
        $r->get('/messages/preview_recipients')->to('messages#preview_recipients')->name('messages_preview_recipients');
        $r->get('/messages/unread_count')->to('messages#unread_count')->name('messages_unread_count');
        $r->get('/messages/:id')->to('messages#show')->name('messages_show');
        $r->post('/messages/:id/mark_read')->to('messages#mark_read')->name('messages_mark_read');

        # Waitlist routes -- must be declared before the /:workflow catch-all
        $r->get('/waitlist/:id')->to('waitlist#show')->name('waitlist_show');
        $r->post('/waitlist/:id/accept')->to('waitlist#accept')->name('waitlist_accept');
        $r->post('/waitlist/:id/decline')->to('waitlist#decline')->name('waitlist_decline');
        $r->get('/waitlist/status')->to('waitlist#parent_status')->name('waitlist_status');

        # Workflow routes -- catch-all, must be declared last among /:path routes
        my $w = $r->any("/:workflow")->to('workflows#');
        $w->get('')->to('#index')->name("workflow_index");
        $w->post('')->to('#start_workflow')->name("workflow_start");
        $w->get("/:run/:step")->to('#get_workflow_run_step')
          ->name("workflow_step");
        $w->post("/:run/:step")->to('#process_workflow_run_step')
          ->name("workflow_process_step");
        $w->post('/:run/callcc/:target')->to('#start_continuation')
          ->name("workflow_callcc");

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

        # Schedule domain verification to run every 15 minutes
        my $existing_domain_verification = $self->minion->jobs({
            tasks => ['domain_verification'],
            states => ['inactive', 'active']
        })->total;

        unless ($existing_domain_verification) {
            $self->minion->enqueue('domain_verification', [], {
                delay => 900, # Start after 15 minutes
                attempts => 3,
                priority => 5
            });

            $self->log->info("Scheduled recurring domain verification job");
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
