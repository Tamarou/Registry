use 5.42.0;
use utf8;
use Object::Pad;

use Registry::DAO;
use Registry::DAO::Workflow;

class Registry::DAO::WorkflowSteps::CreateUser :isa(Registry::DAO::WorkflowStep) {
    use experimental 'keyword_any';

    method process ( $db, $, $run = undef ) {
        $run //= do { my ($w) = $self->workflow($db); $w->latest_run($db) };

        my $data = $run->data;

        # Check for tenant context from workflow run data
        my $user_db = $db;

        # Pass both the database connection and tenant context to User::create
        # Only include defined values to avoid null constraint violations
        my %user_data = ( __tenant_slug => $data->{__tenant_slug} );
        for my $field (qw(username password)) {
            $user_data{$field} = $data->{$field} if defined $data->{$field};
        }

        # The form chooses what kind of account this is; without it every
        # account created here is a parent, because that is the column
        # default. The value is client-supplied and users.user_type is
        # CHECK-constrained, so anything outside the constraint is dropped
        # rather than handed to the database as an exception.
        #
        # Granting a role is not the same as choosing one. user-creation is
        # open to admin AND staff, so copying the requested type through
        # unchecked would let a staff member mint themselves an administrator
        # -- inert while nothing copied the field, a privilege escalation the
        # moment it did. Only an admin may create an admin; anyone else asking
        # for one is refused rather than quietly downgraded, because silently
        # handing back a lesser account than the one just requested is how an
        # operator ends up not knowing who can do what.
        if ( defined $data->{user_type}
            && any { $_ eq $data->{user_type} } qw(parent student staff admin) )
        {
            my $caller = $data->{user} // {};
            my $caller_type = $caller->{user_type} // $caller->{role} // '';

            if ( $data->{user_type} eq 'admin' && $caller_type ne 'admin' ) {
                return {
                    next_step => $self->id,
                    errors    => ['Only an administrator can create an administrator account.'],
                };
            }

            $user_data{user_type} = $data->{user_type};
        }

        # Generate a default username if none provided (required by database constraint)
        if (!defined $user_data{username}) {
            # Use a timestamp-based username to ensure uniqueness
            my $timestamp = time();
            my $rand = int(rand(10000));
            $user_data{username} = "user_${timestamp}_${rand}";
        }

        my $user = Registry::DAO::User->create( $user_db, \%user_data );

        $run->update_data(
            $db,
            {
                password => '',
                passhash => $user->passhash,
                id       => $user->id,
            }
        );

        if ( $run->has_continuation ) {
            my ($continuation) = $run->continuation($db);
            my $users = $continuation->data->{users} // [];
            push $users->@*, { id => $user->id };
            $continuation->update_data( $db, { users => $users } );
        }

        return { user => $user->id };
    }
}