use 5.40.2;
use experimental qw(try);
use Object::Pad;
use Registry::DAO;
use Registry::Job::AttendanceCheck;

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
            PostgreSQL => $ENV{DB_URL} || 'postgresql://localhost/registry'
        });
        
        # Register background jobs
        Registry::Job::AttendanceCheck->register($self);

        $self->helper(
            dao => sub {
                state $db = Registry::DAO->new( url => $ENV{DB_URL} );
            }
        );

        $self->hook(
            before_server_start => sub ( $server, @ ) {
                $self->import_schemas;
                $self->import_templates;
                $self->import_workflows;
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

        my $r = $self->routes->under('/')->to('tenants#setup');
        $r->get('')->to('#index')->name("tenants_landing");

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
    }

    method import_workflows () {
        my $dao = $self->dao;
        my @workflows =
          $self->home->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;

        for my $file (@workflows) {
            my $yaml = $file->slurp;
            next if Load($yaml)->{draft};
            try {
                my $workflow = Workflow->from_yaml( $dao, $yaml );
                my $msg      = sprintf( "Imported workflow '%s' (%s)",
                    $workflow->name, $workflow->slug );
                $self->app->log->debug($msg);
            }
            catch ($e) {
                $self->app->log->error("Error importing workflow: $e");
            }
        }
    }

    method import_templates () {
        my $dao = $self->dao;

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
        my $dao = $self->dao;

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
        my $existing = $self->minion->jobs({
            tasks => ['attendance_check'],
            states => ['inactive', 'active']
        })->total;
        
        unless ($existing) {
            # Schedule to run every minute
            $self->minion->enqueue('attendance_check', [], {
                delay => 60, # Start after 1 minute
                attempts => 3,
                priority => 5
            });
            
            $self->log->info("Scheduled recurring attendance check job");
        }
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
