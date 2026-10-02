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

        return {
            %$data,
            registrations => \@registrations,
            organization  => $self->_organization( $db, $data->{__tenant_slug} ),
        };
    }

    # Whose programme this is, and how to reach them, read from the tenant.
    #
    # The page used to print camp@example.com and (555) 123-4567 at a parent who
    # had just paid and had a question, greet them into "our summer camp
    # program" whatever the tenant actually runs, and promise an information
    # packet nobody sends.
    #
    # Qualified with registry., not left to the search path: this runs on a
    # handle connected to the tenant's own schema, where clone_schema has left
    # an empty copy of `tenants`. An unqualified read finds that copy, returns
    # nothing, and the contact details go quietly missing again -- which is the
    # same silence this is fixing.
    method _organization ( $db, $slug ) {
        $db = $db->db if $db isa Registry::DAO;
        return {} unless defined $slug && length $slug;

        my $row = $db->query( <<~'SQL', $slug )->hash or return {};
            SELECT t.name,
                   tp.billing_email,
                   tp.billing_phone,
                   up.email AS primary_email
              FROM registry.tenants t
              LEFT JOIN registry.tenant_profiles tp ON tp.tenant_id = t.id
              LEFT JOIN registry.tenant_users tu
                     ON tu.tenant_id = t.id AND tu.is_primary IS TRUE
              LEFT JOIN registry.user_profiles up ON up.user_id = tu.user_id
             WHERE t.slug = ?
            SQL

        # billing_email first: it is the address this organization gave for
        # itself. The primary user's own address is the fallback for a tenant
        # that never filled one in -- a real person either way, which is the
        # whole point. Both can be absent, and the page says so rather than
        # inventing a third.
        return {
            name  => $row->{name},
            email => $row->{billing_email} || $row->{primary_email},
            phone => $row->{billing_phone},
        };
    }
}
