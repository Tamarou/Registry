# ABOUTME: Prepares the registration confirmation page shown after a parent pays.
# ABOUTME: Resolves each child's chosen session so the page can name it instead of guessing.
use 5.42.0;
use experimental 'signatures';

use Object::Pad;

class Registry::DAO::WorkflowSteps::RegistrationComplete :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Session;

    # The page reads what MultiChildSessionSelection wrote -- a children
    # snapshot and a child_id => session_id map -- and pairs them up. Doing it
    # here rather than in the template is what lets the page name the session
    # a parent actually picked: the run knows the id, only the database knows
    # the name and the dates.
    method prepare_template_data ( $db, $run, $params = {} ) {
        my $data       = $run->data || {};
        my $selections = $data->{session_selections} || {};

        # 'all' is the same fallback calculate_enrollment_total honours, for
        # program types that put every sibling in one session.
        my %session_for;
        my @registrations;
        for my $child ( ( $data->{children} || [] )->@* ) {
            my $session_id = $selections->{ $child->{id} // '' } // $selections->{all};
            my $session =
              $session_id
              ? ( $session_for{$session_id} //=
                  Registry::DAO::Session->find( $db, { id => $session_id } ) )
              : undef;

            push @registrations, {
                child_name => join( ' ',
                    grep { defined && length }
                      $child->{first_name}, $child->{last_name} ),
                grade   => $child->{grade},
                session => $session,
            };
        }

        return { %$data, registrations => \@registrations };
    }
}
