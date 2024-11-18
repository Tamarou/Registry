use 5.40.0;
use Object::Pad;

class Registry : isa(Mojolicious) {
    our $VERSION = '0.000';

    use Sys::Hostname qw( hostname );
    use Registry::DAO;

    method startup {
        $self->secrets( [hostname] );

        $self->helper(
            dao => sub {
                state $db = Registry::DAO->new( url => $ENV{DB_URL} );
            }
        );

        my $r = $self->routes->under('/')->to('tenants#setup');
        $r->get('')->to('#index')->name("tenants_landing");
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
