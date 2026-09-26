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

        # A child who chose a full session is not enrolled in it -- they are in
        # the queue for it. Telling their parent they are "joining us this
        # summer" claims a seat that does not exist, and reading them out of
        # session_selections (where they deliberately are not) left them on the
        # page with no session named at all.
        my %waiting_for;
        for my $item ( ( $data->{waitlist_items} || [] )->@* ) {
            next unless ref $item eq 'HASH';
            my $child_id = $item->{child_id} // next;
            $waiting_for{$child_id} = $item->{session_id};
        }

        # 'all' is the same fallback calculate_enrollment_total honours, for
        # program types that put every sibling in one session. It applies to
        # seats only: a waiting child's session is the one they queued for.
        my %session_for;
        my @registrations;
        for my $child ( ( $data->{children} || [] )->@* ) {
            my $child_id = $child->{id} // '';
            my $waiting  = exists $waiting_for{$child_id} ? 1 : 0;
            my $session_id =
              $waiting
              ? $waiting_for{$child_id}
              : ( $selections->{$child_id} // $selections->{all} );
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
                waiting => $waiting,
            };
        }

        return { %$data, registrations => \@registrations };
    }
}
