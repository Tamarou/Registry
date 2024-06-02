use 5.38.2;
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

        # routes
        $self->routes->get('/:workflow')->to('workflows#index')
          ->name('workflow');
        $self->routes->post('/:workflow/:step')->to('workflows#start_workflow')
          ->name('workflow_start');
        $self->routes->get('/:workflow/:run/:step')
          ->to('workflows#get_workflow_run_step')->name('workflow_run_step');

        $self->routes->post('/:workflow/:run/:step')
          ->to('workflows#process_workflow_run_step')
          ->name('workflow_process_step');
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

