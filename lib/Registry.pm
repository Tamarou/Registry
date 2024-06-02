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

        my $r = $self->routes;
        $r->add_shortcut(
            workflow => sub ( $r, $name ) {
                my $w =
                  $r->any("/$name")->to( 'workflows#', workflow => $name );
                $w->get('')->to('#index')->name($name);
                $w->post('/start')->to('#start_workflow')
                  ->name("${name}_start");
                $w->get("/:run/:step")->to('#get_workflow_run_step')
                  ->name("${name}_run_step");
                $w->post("/:run/:step")->to('#process_workflow_run_step')
                  ->name("${name}_process_step");
                return $w;
            }
        );

        for my $workflow ( $self->dao->find('Workflow') ) {
            $self->log->debug( "Adding workflow: " . $workflow->slug );
            $r->workflow( $workflow->slug );
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

