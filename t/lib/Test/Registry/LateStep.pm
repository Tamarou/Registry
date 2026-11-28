# ABOUTME: Test-only workflow step whose result settles later, as a step waiting on Stripe does.
# ABOUTME: Before it settles it calls the posted `meanwhile` code, standing in for another process moving the run.
use 5.42.0;
use Object::Pad;

class Test::Registry::LateStep :isa(Registry::DAO::WorkflowStep) {
    use Mojo::Promise;

    method process ( $db, $form_data, $run = undef ) {
        my $meanwhile = $form_data->{meanwhile};
        return Mojo::Promise->resolve->then( sub (@) {
            $meanwhile->() if ref $meanwhile eq 'CODE';
            return { late => 1 };
        } );
    }
}

1;
