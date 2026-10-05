# ABOUTME: Main Mojolicious application class for the Registry project
# ABOUTME: Defines application startup, route configuration, and authentication helpers
use 5.42.0;
use Object::Pad;
use Registry::DAO;
use Registry::Utility::BaseDomain ();
use Registry::Middleware::RateLimit;
use Registry::Job::AttendanceCheck;
use Registry::Job::DomainVerification;
use Registry::Job::InstalmentSchedule;
use Registry::Job::ProcessWaitlist;
use Registry::Job::WaitlistExpiration;
use Registry::Command::schema;
use Registry::Command::template;
use Registry::Command::workflow;

class Registry :isa(Mojolicious) {
    our $VERSION = v0.001;
    use Sys::Hostname            qw( hostname );
    use Mojo::Util               qw( steady_time );
    use YAML::XS                 qw(Load);
    use Registry::Utility::Logger;

    # What production depends on, what happens without it, and whether the value
    # is safe to print. Every consequence here was read out of the code rather
    # than assumed:
    #
    #   DB_URL                 Registry.pm's Pg helper falls back to
    #                          postgresql://localhost/registry -- a different
    #                          database, silently.
    #   BASE_URL               AccountCheck builds magic-link URLs with '' as
    #                          the base.
    #   STRIPE_SECRET_KEY      WorkflowSteps::Payment routes every priced cart
    #                          to create_demo_enrollments: enrolled, not charged.
    #   STRIPE_WEBHOOK_SECRET  Webhooks refuses every delivery with a 500, so no
    #                          payment ever settles.
    #   POSTMARK_SERVER_TOKEN  Notification builds no transport, so nothing is
    #                          delivered.
    #   LOG_LEVEL              the per-request access line is at debug, so it is
    #                          not emitted. This is the one that started #459.
    my @PRODUCTION_CONFIG = (
        { key => 'DB_URL', secret => 1,
          cost => 'the app falls back to postgresql://localhost/registry' },
        { key => 'BASE_URL',
          cost => 'magic-link URLs are built with an empty base' },
        { key => 'STRIPE_SECRET_KEY', secret => 1,
          cost => 'priced enrolments complete WITHOUT charging' },
        { key => 'STRIPE_WEBHOOK_SECRET', secret => 1,
          cost => 'webhooks are refused, so no payment settles' },
        { key => 'POSTMARK_SERVER_TOKEN', secret => 1,
          cost => 'no email is delivered' },
        { key => 'LOG_LEVEL',
          cost => 'the per-request access line is not emitted' },
    );

    method _log_effective_configuration {
        return unless $self->mode eq 'production';

        my @effective;
        my @missing;

        for my $var (@PRODUCTION_CONFIG) {
            my $value = $ENV{ $var->{key} };
            my $set   = defined $value && length $value;

            # A secret is reported present or absent, never echoed: this line
            # goes to a log store, and the point is to see WHETHER a variable
            # arrived, not what it says.
            push @effective, sprintf '%s=%s', $var->{key},
                !$set          ? 'unset'
              : $var->{secret} ? 'set'
              :                  $value;

            push @missing, $var unless $set;
        }

        $self->log->info( 'effective configuration: ' . join ' ', @effective );

        # One line per absence, naming the consequence. At error, because each
        # of these means the product quietly does something other than what it
        # is meant to -- and an operator scanning for errors is the only reader
        # there is until #426.
        $self->log->error(
            sprintf '%s is not set in production: %s', $_->{key}, $_->{cost} )
          for @missing;

        return;
    }

    method startup {
        # Replace default Mojolicious logger with structured JSON logger.
        # Level defaults to the LOG_LEVEL environment variable, falling back to 'info'.
        $self->log(
            Registry::Utility::Logger->new(
                level => $ENV{LOG_LEVEL} // 'info'
            )
        );

        # Say out loud what this process is actually configured with.
        #
        # #459: LOG_LEVEL was committed to render.yaml, the deploy went live
        # with the code, the variable never arrived, and the access log stayed
        # dark for hours. Nothing was broken -- `LOG_LEVEL // 'info'` is a
        # legitimate default, so the feature simply did not happen, which is the
        # hardest kind of configuration failure to notice. A boot line that
        # states the EFFECTIVE value makes the discrepancy visible on the first
        # deploy instead of on the day somebody goes looking.
        $self->_log_effective_configuration;

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
        Registry::Job::InstalmentSchedule->register($self);
        Registry::Job::ProcessWaitlist->register($self);
        Registry::Job::WaitlistExpiration->register($self);

        # Register CSV renderer for data exports with Text::CSV_XS for proper escaping and streaming
        $self->renderer->add_handler(csv => sub ($renderer, $c, $output, $options) {
            use Text::CSV_XS;

            # The stash, not $options. Mojolicious hands a renderer its render
            # OPTIONS -- template, format, handler, encoding -- and the values a
            # controller passes to render() land in the stash. Reading them from
            # $options meant this handler never once saw its data in a real
            # request and always wrote the empty-export placeholder. The
            # renderer's own unit test passed because it called the handler
            # directly with a hand-built $options, which is the one arrangement
            # production never produces.
            my $data = $c->stash('csv') // $options->{csv} // [];
            my $chunk_size = $c->stash('chunk_size') // $options->{chunk_size} // 1000;
            my $stream = $c->stash('stream') // $options->{stream} // 0;

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
                # Acting as a tenant requires MEMBERSHIP of it, not merely a
                # login. This value becomes __tenant_slug, which selects the
                # Postgres schema every subsequent query runs against and the
                # Stripe Connect account a charge is destined for -- so
                # authentication alone let any logged-in user read and write
                # another tenant's database and point settlement elsewhere.
                #
                # req->cookie returns a Mojo::Cookie::Request OBJECT, not a
                # string. Passing it through stringified it to
                # "as-tenant=<slug>", which failed the slug regex below and fell
                # back to registry -- so the cookie half has never worked at all,
                # including for t/playwright/payment-smoke.spec.js, which sets it
                # and expects to be routed to a tenant.
                # Skipped entirely when an explicit tenant is passed. That is
                # not just an optimisation: the membership check below goes
                # through $c->dao('registry'), and the dao helper calls
                # $c->tenant(...) -- so without this short-circuit the recursive
                # call re-enters here and never terminates. An explicit argument
                # wins over the header regardless.
                my $header_tenant;
                if ( !$explicit_tenant
                    && ( $c->session('user_id') || $c->stash('current_user') ) ) {
                    my $cookie    = $c->req->cookie('as-tenant');
                    my $requested = $c->req->headers->header('X-As-Tenant')
                                 || ( $cookie ? $cookie->value : undef );
                    $header_tenant = $self->_acting_tenant_for( $c, $requested );
                }

                my $subdomain_tenant = $self->_extract_tenant_from_subdomain($c);
                my $raw = $explicit_tenant
                    || $header_tenant
                    || $subdomain_tenant;

                # Whether $raw came from the (heuristic) subdomain path -- the
                # only path the defensive schema check guards (explicit param,
                # X-As-Tenant, and verified custom domains are deliberate or
                # already validated).
                my $from_subdomain = !$explicit_tenant
                    && !$header_tenant
                    && defined $subdomain_tenant;

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

                return $raw if $raw eq 'registry';

                # Defensive fallback (subdomain path only): if a subdomain-resolved
                # tenant has no Postgres schema, degrade to the registry/platform
                # site instead of letting a "relation does not exist" 500 escape.
                # Explicit param / X-As-Tenant / verified custom domains are
                # deliberate and not second-guessed here. Cache positive
                # (schema-exists) results per process to bound the catalog query
                # to once per valid tenant; never cache a miss, so a freshly
                # provisioned schema is picked up on its next request.
                return $raw unless $from_subdomain;
                state %schema_exists;
                unless ( $schema_exists{$raw} ) {
                    my $found = eval {
                        my $registry_dao = $c->dao('registry');
                        $registry_dao->db->query(
                            'SELECT 1 FROM information_schema.schemata WHERE schema_name = ?',
                            $raw
                        )->rows;
                    };
                    my $eval_err = $@;

                    if ($found) {
                        # Query succeeded and found the schema -- cache the hit.
                        $schema_exists{$raw} = 1;
                    }
                    elsif ($eval_err) {
                        # The eval threw: a DB or infrastructure error, not a
                        # schema miss.  Log distinctly at ERROR so operators can
                        # tell "tenant schema genuinely absent" from "DB is down".
                        # Resilience is preserved either way (serve registry).
                        $c->app->log->error(
                            "schema-existence check failed for tenant '$raw': $eval_err; serving registry");
                        return 'registry';
                    }
                    else {
                        # Query succeeded but returned 0 rows: schema genuinely absent.
                        $c->app->log->warn(
                            "tenant '$raw' resolved but has no schema; serving registry");
                        return 'registry';
                    }
                }

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
        #
        # Returns undef for a deactivated account, which is what revokes access.
        # Placed here rather than at each auth path because both of them -- API key
        # and session cookie -- funnel through this one sub, so this is the single
        # point that covers a cookie already in a browser, a bearer token already
        # issued, and anything added later that stashes a user the same way.
        #
        # The effect is that a deactivation lands on the offboarded person's very
        # next request, rather than whenever their session happens to expire. For
        # someone who has been walked out, "next request" is the only acceptable
        # answer.
        my $user_to_stash = sub ($user, %extra) {
            return undef unless $user->is_active;

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
                                my $stashed = $user_to_stash->($user, api_key => $api_key);
                                $c->stash( current_user => $stashed ) if $stashed;
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
                    if ($user) {
                        my $stashed = $user_to_stash->($user);
                        if ($stashed) {
                            $c->stash( current_user => $stashed );
                        }
                        else {
                            # Deactivated while signed in. Clear the session too, so
                            # the next request does not repeat this lookup and so
                            # anything reading session('user_id') directly agrees
                            # with current_user.
                            delete $c->session->{user_id};
                        }
                    }
                }
                catch ($e) {
                    $c->app->log->warn("Failed to load current_user from session: $e");
                }
            }
        );

        # Wire per-request log correlation context so every JSON log line carries
        # request_id, user_id, and tenant_id for distributed tracing / log analysis.
        # Registered after the user-loading hook above so current_user is known.
        # set_context replaces context each request, so stale context cannot leak
        # across requests even if after_dispatch is skipped on error.
        $self->hook(
            before_dispatch => sub ($c) {
                # Stamped here so the access line can report how long the
                # request took. Nothing else measures a request end to end:
                # #428 is a journey that takes three minutes with no way to say
                # which of its requests spent them. steady_time, not time, so a
                # clock adjustment mid-request cannot produce a negative
                # duration.
                $c->stash( request_started => steady_time );

                $c->app->log->set_context({
                    request_id => $c->req->request_id,
                    user_id    => $c->session('user_id'),
                    tenant_id  => $c->tenant,
                }) if $c->app->log->can('set_context');
            }
        );

        # The request path as it is safe to write down.
        #
        # The real path, not the matched route pattern: /:workflow/:run/:step
        # would collapse every page of every funnel into one line, and which
        # workflow and which step is the entire signal this line exists for. The
        # run id is what stitches a visitor's requests into a single journey.
        #
        # But one of those paths is a credential. GET /auth/magic/:token is
        # still redeemable when this line is written -- that request only renders
        # the confirmation page, and the POST after it establishes the session --
        # so logging it verbatim puts a working login in the log store for as
        # long as the token lives. Logger's _redact cannot help: it knows
        # key=value shapes and card-like digit runs, not path segments.
        #
        # Masked by capture NAME rather than by matching the path against a list
        # of routes, so a route added later with a :token placeholder is covered
        # without anybody remembering that this line exists.
        my sub loggable_path ($c) {
            my $path = $c->req->url->path->to_string;

            for my $captures ( @{ $c->match->stack // [] } ) {
                for my $name ( grep { /token/ } keys %$captures ) {
                    my $value = $captures->{$name};
                    next unless defined $value && length $value;
                    $path =~ s/\Q$value\E/[REDACTED]/g;
                }
            }

            return $path;
        }

        $self->hook(
            after_dispatch => sub ($c) {
                # Emit a structured access log line while context is still set,
                # so every request produces at least one line carrying request_id,
                # user_id, and tenant_id for correlation in log analysis tools.
                # '-' rather than 0 when the stamp is missing: a request
                # that bypassed before_dispatch has an unknown duration, and a
                # zero would average into the percentiles as a fast one.
                my $started = $c->stash('request_started');

                # Render probes /health every five seconds, which at debug is
                # some seventeen thousand lines a day saying the service is up
                # -- something Render already reports on its own. Logged, that
                # becomes the whole log and buries the requests somebody
                # actually made: measured at eleven health checks to one real
                # request on the day the level was turned up.
                #
                # Skipped by not logging rather than by returning early: the
                # context still has to be cleared below.
                my $is_health_probe = $c->req->url->path eq '/health';

                $c->app->log->debug(
                    sprintf '%s %s %s %s',
                        $c->req->method,
                        loggable_path($c),
                        $c->res->code // 0,
                        defined $started
                            ? sprintf( '%.0fms', ( steady_time - $started ) * 1000 )
                            : '-',
                ) if !$is_health_probe && $c->app->log->can('set_context');

                $c->app->log->clear_context()
                    if $c->app->log->can('clear_context');
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

        # Helper: is this Alex?
        #
        # #426's blocker: the app could ask "what role does this user have in
        # this tenant" and could not ask "is this the platform's owner". Those
        # are different questions and the second had no answer, which is why
        # there is no platform surface at all -- nothing could be put behind
        # anything.
        #
        # Deliberately not a user_type. check_user_type caps that column at
        # parent/student/staff/admin, and Morgan running a studio is every bit
        # as much an 'admin' as Alex; what distinguishes them is which tenant
        # they are primary of. See Registry::DAO::Tenant::is_platform_admin.
        $self->helper(
            require_platform_admin => sub ($c) {
                return 0 unless $c->require_auth;

                my $user = $c->stash('current_user');
                require Registry::DAO::Tenant;
                return 1 if Registry::DAO::Tenant->is_platform_admin(
                    $c->dao->db, ref $user ? $user->{id} : undef );

                # 403 rather than 404: hiding the route from a signed-in tenant
                # admin buys nothing -- they can read the same refusal from the
                # status code either way -- and a plain Forbidden is what
                # require_role already answers, so the two surfaces agree.
                if (   $c->req->headers->header('X-Requested-With')
                    || ( $c->req->headers->accept // '' ) =~ m{application/json} )
                {
                    $c->render( json => { error => 'Forbidden' }, status => 403 );
                }
                else {
                    $c->render( text => 'Forbidden', status => 403 );
                }
                return 0;
            }
        );

        # Helper: enforce whatever role a workflow slug demands, if it demands
        # one. Shared by the /:workflow guard and by the callcc leg, which
        # starts a run of a workflow the URL names in a different placeholder.
        # Returns true when the request may proceed.
        $self->helper(
            require_workflow_role => sub ( $c, $slug ) {
                my $roles = $self->workflow_roles($slug) or return 1;
                return $c->require_role(@$roles);
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

                # The URL of the page is itself a secret on two routes:
                # /auth/magic/:token and /auth/verify-email/:token carry a
                # credential in the path, and every page in this layout pulls a
                # stylesheet from fonts.googleapis.com. Modern browsers default
                # to strict-origin-when-cross-origin and would send only the
                # origin, so this asserts the behaviour rather than inheriting
                # it -- an older browser, or a future one with a looser default,
                # would otherwise hand a live magic-link URL to a third party in
                # a Referer header. #450.
                $headers->header(
                    'Referrer-Policy' => 'strict-origin-when-cross-origin' );

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

        # Health check / readiness probe endpoint (no auth required).
        # Performs a trivial SELECT 1 against the registry DB so that the probe
        # reflects actual database reachability, not just process liveness.
        # Returns HTTP 200 on success, HTTP 503 when the DB is unavailable.
        $self->routes->get('/health')->to(cb => sub ($c) {
            my $ts = time();
            eval {
                $c->dao('registry')->db->query('SELECT 1');
            };
            if ($@) {
                my $err = $@;
                $c->app->log->error("Health check DB probe failed: $err");
                $c->render(
                    json   => { status => 'error', db => 'down', timestamp => $ts },
                    status => 503,
                );
                return;
            }
            $c->render(json => { status => 'ok', db => 'ok', timestamp => $ts });
        })->name('health_check');

        # Webhook routes (no auth required)
        $self->routes->post('/webhooks/stripe')->to('webhooks#stripe')
          ->name('webhook_stripe');

        # Root route dispatches to whichever storefront belongs to the
        # requester -- see storefront_workflow. It deliberately names no
        # workflow: a static one here is what made the apex serve a tenant's.
        $self->routes->get('/')->to('workflows#index')->name('root_handler');
        $self->routes->post('/')->to('workflows#start_workflow');

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
        $admin->get('/dashboard/outstanding_instalments')->to('admin_dashboard#outstanding_instalments')->name('admin_dashboard_outstanding_instalments');
        $admin->get('/dashboard/enrollment_trends')->to('admin_dashboard#enrollment_trends')->name('admin_dashboard_enrollment_trends');
        $admin->get('/dashboard/export')->to('admin_dashboard#export_data')->name('admin_dashboard_export');
        $admin->post('/dashboard/send_bulk_message')->to('admin_dashboard#send_bulk_message')->name('admin_dashboard_send_bulk_message');
        $admin->get('/dashboard/pending_drop_requests')->to('admin_dashboard#pending_drop_requests')->name('admin_dashboard_pending_drop_requests');
        $admin->post('/dashboard/process_drop_request')->to('workflows#start_workflow' => { workflow => 'admin-drop-approval' })->name('admin_dashboard_process_drop_request');
        $admin->get('/dashboard/pending_transfer_requests')->to('admin_dashboard#pending_transfer_requests')->name('admin_dashboard_pending_transfer_requests');
        $admin->post('/dashboard/process_transfer_request')->to('workflows#start_workflow' => { workflow => 'admin-transfer-approval' })->name('admin_dashboard_process_transfer_request');

        # Offboarding. A departed staff member has to lose access without losing
        # the history that points at them -- events.teacher_id and
        # attendance_records.marked_by are NOT NULL references to their row.
        $admin->get('/people')->to('people#index')->name('admin_people');
        $admin->post('/people/:id/deactivate')->to('people#deactivate')->name('admin_people_deactivate');
        $admin->post('/people/:id/reactivate')->to('people#reactivate')->name('admin_people_reactivate');
        $admin->post('/people/:id/invite')->to('people#invite')->name('admin_people_invite');

        $admin->get('/templates')->to('workflows#index', workflow => 'template-editor')->name('admin_templates');
        $admin->post('/templates')->to('workflows#start_workflow', workflow => 'template-editor');

        # Publish / unpublish programs and sessions.
        $admin->post('/programs/:id/status')
            ->to('admin_dashboard#set_program_status')
            ->name('admin_program_status');
        $admin->post('/sessions/:id/status')
            ->to('admin_dashboard#set_session_status')
            ->name('admin_session_status');

        # Minion's own dashboard, behind the platform guard.
        #
        # #426's first step, and the cheapest: the job queue is the answer to
        # "is the automation running" and it was answerable only through psql or
        # `registry minion job`. Mounting what Minion already ships retires more
        # terminal work than anything else on that list.
        #
        # Under its own `under` rather than $admin_only: that group asks
        # require_role('admin'), which Morgan satisfies -- and the queue is every
        # tenant's work, so it is not a tenant admin's to read.
        #
        # route => the mount point, so links inside the dashboard stay under it.
        my $platform = $r->under('/platform')->to(
            cb => sub ($c) { $c->require_platform_admin } );
        $platform->get('/')->to( cb => sub ($c) {
            $c->redirect_to('/platform/tenants');
        } )->name('platform_index');

        $self->plugin( 'Minion::Admin' => { route => $platform->any('/jobs') } );

        # The tenant fleet: #426's step 2, and the screen everything else about
        # a customer hangs off. "Is this customer actually working" took four
        # psql checks per tenant -- the row, the schema, the imports, and
        # whether the owner is resident in both schemas -- which is why a
        # half-provisioned tenant stayed invisible until somebody complained.
        $platform->get('/tenants')->to( cb => sub ($c) {
            require Registry::DAO::Tenant;
            $c->render(
                template => 'platform/tenants',
                fleet    => Registry::DAO::Tenant->fleet( $c->dao->db ),
            );
        } )->name('platform_tenants');

        # Domain management routes: admin-only (staff cannot access)
        # This is a separate under() group from $admin so that staff cannot reach
        # these routes even though staff can reach other /admin/* routes.
        my $admin_only = $r->under('/admin')->to(
            cb => sub ($c) { $c->require_role('admin') }
        );
        # Stripe Connect onboarding: admin-only, like domains. It decides where
        # the money lands and it is the tenant's own Stripe identity, so staff
        # who can otherwise reach /admin/* do not get to start or change it.
        $admin_only->get('/billing')->to('StripeConnect#index')->name('admin_billing');
        $admin_only->post('/billing/connect')->to('StripeConnect#start')->name('admin_billing_connect');
        $admin_only->get('/billing/refresh')->to('StripeConnect#refresh')->name('admin_billing_refresh');
        $admin_only->get('/billing/return')->to('StripeConnect#finish')->name('admin_billing_return');

        $admin_only->get('/domains')->to('TenantDomains#index')->name('admin_domains');
        $admin_only->post('/domains')->to('TenantDomains#add')->name('admin_domains_add');
        $admin_only->post('/domains/:id/verify')->to('TenantDomains#verify')->name('admin_domains_verify');
        $admin_only->post('/domains/:id/primary')->to('TenantDomains#set_primary')->name('admin_domains_primary');
        $admin_only->post('/domains/:id/remove')->to('TenantDomains#remove')->name('admin_domains_remove');

        # Auth routes (unprotected -- no require_auth)
        my $auth = $r->under('/auth');
        $auth->get('/login')->to('Auth#login');
        $auth->get('/magic-link-sent')->to('Auth#magic_link_sent');
        $auth->post('/magic/request')->to('Auth#request_magic_link');
        $auth->get('/magic/poll/:token_hash')->to('Auth#magic_link_status');
        $auth->post('/magic/poll/:token_hash/complete')->to('Auth#magic_link_complete_by_hash');
        $auth->get('/magic/:token')->to('Auth#verify_magic_link');
        $auth->post('/magic/:token/complete')->to('Auth#complete_magic_link');
        $auth->post('/logout')->to('Auth#logout');
        $auth->get('/verify-email/:token')->to('Auth#verify_email');
        $auth->get('/register-passkey')->to('Auth#register_passkey');
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
        # /waitlist/status must be declared before /waitlist/:id, or the literal
        # is captured as an :id and cast to a uuid.
        $r->get('/waitlist/status')->to('waitlist#parent_status')->name('waitlist_status');
        $r->get('/waitlist/:id')->to('waitlist#show')->name('waitlist_show');
        $r->post('/waitlist/:id/accept')->to('waitlist#accept')->name('waitlist_accept');
        $r->post('/waitlist/:id/decline')->to('waitlist#decline')->name('waitlist_decline');

        # Workflow routes -- catch-all, must be declared last among /:path routes.
        # Nothing stood between a workflow slug and an anonymous visitor here:
        # the controller checks no role of its own, so every admin surface was
        # reachable by anyone who knew its slug. The guard is per-slug rather
        # than blanket because the acquisition funnels live under this same
        # catch-all -- see workflow_roles.
        my $w = $r->under("/:workflow")->to( 'workflows#',
            cb => sub ($c) {
                # An unknown slug is a 404 before anything dereferences the
                # workflow it did not find. This is the most public surface in
                # the app and the catch-all for every unmatched path, so what
                # arrives here is mostly crawlers: answering 500 says "this
                # broke" where the truth is "that does not exist", and buries
                # real failures in the one log an operator reads. #431.
                # Resolved here rather than through Workflows::workflow():
                # inside an under callback $c is a plain
                # Mojolicious::Controller, so the controller's own method is
                # not available -- asking for it is itself a 500.
                my $slug = $c->stash('workflow');

                # Serveable, which is not the same as "has a workflow row in
                # this schema". `index` renders a legacy `{slug}/index` template
                # without needing a row at all, and that is how a platform
                # funnel like tenant-signup is served from a TENANT host, where
                # the row lives only in the registry schema. Checking the row
                # alone 404'd an anonymous prospect reaching signup from a
                # tenant domain -- caught by
                # t/security/workflow-route-authorization.t, which exists for
                # exactly that visitor.
                my $serveable = $slug
                  && ( $c->dao->find( 'Registry::DAO::Workflow', { slug => $slug } )
                    || $c->app->renderer->template_path({
                           template => "$slug/index",
                           format   => 'html',
                           handler  => 'ep',
                       }) );

                unless ($serveable) {
                    # Rendered AND false: an under callback that returns true
                    # lets dispatch carry on into the action, which is how this
                    # first attempt still reached
                    # _find_or_create_run's `$workflow->slug` -- the second
                    # undefended dereference #431 names.
                    $c->reply->not_found;
                    return 0;
                }

                return $c->require_workflow_role($slug);
            } );
        $w->get('')->to('#index')->name("workflow_index");
        $w->post('')->to('#start_workflow')->name("workflow_start");

        # A run id is a uuid, so a path segment that cannot be one does not name
        # a run and never reaches a query. Production was taking four of these
        # an hour from crawler traffic on /<workflow>/session/<step>, where
        # 'session' hit the uuid cast inside the SELECT and raised
        # `invalid input syntax for type uuid` -- a database error in the log,
        # indistinguishable at a glance from a real one. Constrained here rather
        # than guarded in the controller because a route that does not match is
        # a 404 with no code at all. #431.
        my $UUID = qr/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/;
        $w->get( "/:run/:step" => [ run => $UUID ] )->to('#get_workflow_run_step')
          ->name("workflow_step");
        $w->post( "/:run/:step" => [ run => $UUID ] )->to('#process_workflow_run_step')
          ->name("workflow_process_step");
        $w->post( '/:run/callcc/:target' => [ run => $UUID ] )
          ->to('#start_continuation')->name("workflow_callcc");

    }

    # Which storefront belongs to the requester.
    #
    # The apex has no subdomain, so `tenant` falls back to registry (see the
    # helper at :169). Pointing the root route at tenant-storefront therefore
    # made the PLATFORM render a tenant's template -- and the only way to get
    # the platform's own marketing page onto tinyartempire.com was to hand-edit
    # registry's copy of that tenant template, which is why exactly one row in
    # registry.templates has an updated_at that differs from its created_at.
    #
    # The platform has its own storefront instead.
    # Membership of the all-zeros platform tenant. That is how
    # create-default-pricing-relationships and the tier seed both identify a
    # platform admin, and production carries exactly one such row.
    method _PLATFORM_TENANT_ID { '00000000-0000-0000-0000-000000000000' }

    # The tenant an authenticated user is permitted to act as, or undef.
    # A member may act as their own tenant; a platform admin may act as any.
    method _acting_tenant_for ($c, $requested) {
        return undef unless defined $requested && length $requested;
        # Same shape the caller enforces; checked here too so a malformed value
        # never reaches the query.
        return undef unless $requested =~ /\A[a-z][a-z0-9_]{0,62}\z/;

        my $user_id = $c->session('user_id')
          || ( $c->stash('current_user') // {} )->{id};
        return undef unless $user_id;

        my $permitted = eval {
            $c->dao('registry')->db->query( <<~'SQL', $user_id, $requested, $self->_PLATFORM_TENANT_ID )->array;
                SELECT 1
                  FROM registry.tenant_users tu
                 WHERE tu.user_id = ?
                   AND ( tu.tenant_id = (SELECT id FROM registry.tenants WHERE slug = ?)
                         OR tu.tenant_id = ?::uuid )
                 LIMIT 1
                SQL
        };
        if ($@) {
            $c->app->log->warn("Tenant membership check failed: $@");
            return undef;
        }
        return $permitted ? $requested : undef;
    }

    method storefront_workflow ($tenant) {
        return $tenant eq 'registry' ? 'registry-storefront' : 'tenant-storefront';
    }

    # The roles a workflow slug demands of whoever reaches it directly, or
    # undef for the ones anybody may walk into.
    #
    # This names what must be GUARDED rather than what may be public, because
    # the public set is open-ended: a project's registration_workflow metadata
    # aims the storefront's call-to-action at whichever workflow the tenant
    # chose (templates/tenant-storefront/program-listing.html.ep), so an
    # allow-list of public slugs would quietly close a tenant's own funnel.
    # tenant-signup and summer-camp-registration are the two acquisition
    # funnels and must stay anonymous -- registration creates the visitor's
    # account partway through, at its account-check step, so even requiring a
    # login would be wrong.
    #
    # A slug earns a role here when its steps write tenant-owned configuration
    # or act on records the visitor does not own.
    method workflow_roles ($slug) {
        state %ROLES = (
            # Admin tooling: the dashboard and the approval flows that settle
            # other people's drop and transfer requests, plus every builder
            # that writes programs, locations, sessions, pricing, users,
            # templates and workflows. attendance-check is a background job
            # workflow and is not a visitor-facing surface at all.
            ( map { $_ => [ 'admin', 'staff' ] } qw(
                admin-dashboard
                admin-drop-approval
                admin-transfer-approval
                attendance-check
                drop-request-processing
                event-creation
                location-creation
                location-management
                outcome-definition-creation
                pricing-plan-creation
                program-creation
                program-creation-enhanced
                program-location-assignment
                program-setup
                program-type-management
                project-creation
                session-creation
                template-editor
                transfer-request-processing
                user-creation
                workflow-creation
                workflow-step-creation
            ) ),

            # A parent acts on their own enrollment; staff and admins reach the
            # same flows on a family's behalf.
            ( map { $_ => [ 'parent', 'admin', 'staff' ] } qw(
                parent-drop-request
                parent-transfer-request
            ) ),
        );
        return $ROLES{ $slug // '' };
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

    # Platform base domains under which wildcard tenant subdomains are served.
    # Defaults to the platform's own domains so production works with no extra
    # configuration; REGISTRY_BASE_DOMAINS (comma-separated) overrides the default
    # for other environments (e.g. staging). The list lets us tell a tenant
    # subdomain (<slug>.<base>) from the platform apex (<base> itself) and from
    # custom domains (under no base) -- without it the apex domain's own label is
    # wrongly taken as a tenant slug. 'localhost' is included so the test
    # convention <slug>.localhost keeps working.
    method _base_domains {
        return Registry::Utility::BaseDomain::base_domains();
    }

    method _extract_tenant_from_subdomain ($c) {
        my $host = lc( $c->req->headers->host || '' );
        # Remove port if present
        $host =~ s/:\d+$//;

        # Don't extract tenant from IP addresses
        return if $host =~ /^\d+\.\d+\.\d+\.\d+$/;

        # A tenant subdomain is exactly one label under a known base domain:
        # <slug>.<base> -> slug. The bare apex (<base>) has no subdomain, and a
        # host under no configured base is a custom domain (resolved elsewhere).
        for my $base ( $self->_base_domains ) {
            next unless length $base;
            return if $host eq $base;                       # apex: no subdomain
            if ( $host =~ /\A([^.]+)\.\Q$base\E\z/ ) {
                my $subdomain = $1;
                return $subdomain unless $subdomain eq 'www';
                return;
            }
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
