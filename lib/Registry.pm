use 5.40.2;
use experimental qw(try);
use Object::Pad;
use Registry::DAO;
use Registry::Job::AttendanceCheck;
use Registry::Job::ProcessWaitlist;
use Registry::Job::WaitlistExpiration;

class Registry :isa(Mojolicious) {
    our $VERSION = v0.001;
    use Sys::Hostname qw( hostname );
    use YAML::XS      qw(Load);

    method startup {
        $self->secrets( [hostname] );

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

        $self->hook(
            before_server_start => sub ( $server, @ ) {
                $self->import_schemas;
                $self->import_templates;
                $self->import_workflows(); # Use defaults: schema='registry', files=undef, verbose=0
                $self->setup_recurring_jobs;
            }
        );

        # Teacher routes (before tenant setup to avoid conflicts)
        my $teacher = $self->routes->under('/teacher')->to('teacher_dashboard#auth_check');
        $teacher->get('/')->to('#dashboard')->name('teacher_dashboard');
        $teacher->get('/attendance/:event_id')->to('#attendance')->name('teacher_attendance');
        $teacher->post('/attendance/:event_id')->to('#mark_attendance')->name('teacher_mark_attendance');
        
        # Public school pages (no auth required)
        $self->routes->get('/school/:slug')->to('schools#show')
          ->name('show_school');
          
        # Health check endpoint (no auth required)
        $self->routes->get('/health')->to(cb => sub ($c) {
            # Basic health check - verify database connectivity
            eval {
                my $dao = $c->app->dao;
                $dao->pg->db->query('SELECT 1');
            };
            
            if ($@) {
                $c->render(json => { status => 'error', message => 'Database connection failed' }, status => 503);
            } else {
                $c->render(json => { status => 'ok', timestamp => time() });
            }
        })->name('health_check');

        # Webhook routes (no auth required)
        $self->routes->post('/webhooks/stripe')->to('webhooks#stripe')
          ->name('webhook_stripe');
          
        # Route handling for root path - always use default workflow landing page
        $self->routes->get('/')->to('landing#root')->name('root_handler');

        my $r = $self->routes;

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
        
        # Parent Dashboard routes
        $r->get('/parent/dashboard')->to('parent_dashboard#index')->name('parent_dashboard');
        $r->get('/parent/dashboard/upcoming_events')->to('parent_dashboard#upcoming_events')->name('parent_dashboard_upcoming_events');
        $r->get('/parent/dashboard/recent_attendance')->to('parent_dashboard#recent_attendance')->name('parent_dashboard_recent_attendance');
        $r->get('/parent/dashboard/unread_messages_count')->to('parent_dashboard#unread_messages_count')->name('parent_dashboard_unread_messages_count');
        $r->post('/parent/dashboard/drop_enrollment')->to('parent_dashboard#drop_enrollment')->name('parent_dashboard_drop_enrollment');
        
        # Admin Dashboard routes
        $r->get('/admin/dashboard')->to('admin_dashboard#index')->name('admin_dashboard');
        $r->get('/admin/dashboard/program_overview')->to('admin_dashboard#program_overview')->name('admin_dashboard_program_overview');
        $r->get('/admin/dashboard/todays_events')->to('admin_dashboard#todays_events')->name('admin_dashboard_todays_events');
        $r->get('/admin/dashboard/waitlist_management')->to('admin_dashboard#waitlist_management')->name('admin_dashboard_waitlist_management');
        $r->get('/admin/dashboard/recent_notifications')->to('admin_dashboard#recent_notifications')->name('admin_dashboard_recent_notifications');
        $r->get('/admin/dashboard/enrollment_trends')->to('admin_dashboard#enrollment_trends')->name('admin_dashboard_enrollment_trends');
        $r->get('/admin/dashboard/export')->to('admin_dashboard#export_data')->name('admin_dashboard_export');
        $r->post('/admin/dashboard/send_bulk_message')->to('admin_dashboard#send_bulk_message')->name('admin_dashboard_send_bulk_message');
    }

    method import_workflows ($schema = 'registry', $files = undef, $verbose = 0) {
        # Import workflows to specified schema (default: registry)
        my $dao = $self->dao($schema);
        my @workflows = $files ? @$files : 
          $self->home->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;

        for my $file (@workflows) {
            my $yaml = $file->slurp;
            next if Load($yaml)->{draft};
            try {
                my $workflow = Workflow->from_yaml( $dao, $yaml );
                my $msg = sprintf( "Imported workflow '%s' (%s)",
                    $workflow->name, $workflow->slug );
                
                if ($verbose) {
                    my $step_count = scalar @{ Load($yaml)->{steps} // [] };
                    say sprintf "Imported workflow '%s' (%s) with %d steps",
                        $workflow->name, $workflow->slug, $step_count;
                } else {
                    $self->app->log->debug($msg);
                }
            }
            catch ($e) {
                my $error_msg = "Error importing workflow: $e";
                if ($verbose) {
                    warn $error_msg;
                } else {
                    $self->app->log->error($error_msg);
                }
            }
        }
    }

    method import_templates () {
        # Import templates to main registry schema
        my $dao = $self->dao('registry');

        my @templates =
          $self->app->home->child('templates')
          ->list_tree->grep(qr/\.html\.ep$/)->each;

        for my $file (@templates) {
            Registry::DAO::Template->import_from_file( $dao, $file );
            my $msg =
              sprintf( "Imported template '%s'", $file->to_rel('templates') );
            $self->app->log->debug($msg);
        }
    }

    method import_schemas () {
        # Import schemas to main registry schema
        my $dao = $self->dao('registry');

        my @schemas =
          $self->home->child('schemas')->list->grep(qr/\.json$/)->each;

        for my $file (@schemas) {
            try {
                my $outcome =
                  Registry::DAO::OutcomeDefinition->import_from_file( $dao,
                    $file );
                my $msg =
                  sprintf( "Imported outcome definition '%s'", $outcome->name );
                $self->app->log->debug($msg);
            }
            catch ($e) {
                $self->app->log->error("Error importing schema: $e");
            }
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
        return undef if $host =~ /^\d+\.\d+\.\d+\.\d+$/;
        
        # Extract tenant from subdomain: tenant.example.com -> tenant
        if ($host =~ /^([^.]+)\./) {
            my $subdomain = $1;
            return $subdomain unless $subdomain eq 'www';
        }
        return undef;
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
