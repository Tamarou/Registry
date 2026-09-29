# ABOUTME: Admin screen listing the tenant's people, with deactivation for those who leave.
# ABOUTME: Deactivation is the offboarding path: the row stays because its history does.
use 5.42.0;
use utf8;
use Object::Pad;

class Registry::Controller::People :isa(Registry::Controller) {
    use Registry::DAO::User;
    use Registry::DAO::Tenant;

    method index {
        my $dao = $self->dao;

        # Staff and admins only. Parents belong to families and are reached
        # through the family they are part of, not through an operator's staff
        # list -- putting them here would make the common case (find a colleague)
        # the needle in the uncommon one.
        # One call per role, not `user_type => ['admin','staff']`. User::list binds
        # each filter value straight into `u.$key = ?`, so an arrayref stringifies
        # to ARRAY(0x...) and matches nothing at all -- silently. See #434.
        #
        # Sorted by the name a person is actually shown under, so the list reads
        # like a staff list rather than like insertion order.
        my @people =
          sort { lc( $a->name || $a->username ) cmp lc( $b->name || $b->username ) }
          map  { @{ Registry::DAO::User->list( $dao->db, { user_type => $_ } ) } }
          qw( admin staff );

        $self->render(
            template => 'admin/people/index',
            people   => \@people,
        );
    }

    # POST /admin/people/:id/invite
    #
    # Signup creates team members but does not mail them: it is an anonymous
    # form, and mailing addresses typed into one makes it an outbound mailer for
    # whoever the caller names (#438). Sending from here requires a signed-in
    # admin, which is itself proof they hold the address the tenant was created
    # with.
    method invite {
        my $dao  = $self->dao;
        my $user = Registry::DAO::User->find( $dao->db, { id => $self->param('id') } );

        unless ($user) {
            $self->flash( error => 'That account no longer exists.' );
            return $self->redirect_to('admin_people');
        }

        unless ( $user->email ) {
            $self->flash( error => sprintf(
                '%s has no email address on file, so there is nowhere to send an invitation.',
                $user->name || $user->username ) );
            return $self->redirect_to('admin_people');
        }

        # Reached through the registry schema, because that is where the tenants
        # row lives; invite_user then works on the tenant's own handle.
        my $tenant = Registry::DAO::Tenant->find(
            $self->dao('registry')->db, { slug => $self->tenant } );

        unless ($tenant) {
            $self->flash( error => 'This organization could not be resolved.' );
            return $self->redirect_to('admin_people');
        }

        my $acting = $self->stash('current_user') // {};

        if ( $tenant->invite_user( $self->dao('registry')->db, $user,
                $acting->{name} || $acting->{username} || '' ) )
        {
            $self->flash( success => sprintf(
                'Invitation sent to %s. The link is good for seven days.',
                $user->email ) );
        }
        else {
            # invite_user warns with the reason and returns false rather than
            # dying, so a failed send is reportable instead of a 500.
            $self->flash( error => sprintf(
                'The invitation to %s could not be sent. Please try again.',
                $user->email ) );
        }

        return $self->redirect_to('admin_people');
    }

    method deactivate {
        my $dao  = $self->dao;
        my $user = Registry::DAO::User->find( $dao->db, { id => $self->param('id') } );

        unless ($user) {
            $self->flash( error => 'That account no longer exists.' );
            return $self->redirect_to('admin_people');
        }

        my $acting = $self->stash('current_user') // {};

        try {
            # The acting user's id is passed so the DAO can refuse a
            # self-deactivation: a solo operator IS the tenant, and locking
            # themselves out is unrecoverable without database access.
            $user->deactivate( $dao->db, $acting->{id} );
            $self->flash( success =>
                sprintf( '%s can no longer sign in. Their history is unchanged.',
                    $user->name || $user->username ) );
        }
        catch ($e) {
            # The DAO croaks with a sentence meant for a person; show it rather
            # than a generic failure, because both refusals it raises are things
            # the operator needs to act on differently.
            my $why = $e;
            $why =~ s/ at \S+ line \d+\.?\s*\z//;
            $self->flash( error => $why );
        }

        return $self->redirect_to('admin_people');
    }

    method reactivate {
        my $dao  = $self->dao;
        my $user = Registry::DAO::User->find( $dao->db, { id => $self->param('id') } );

        unless ($user) {
            $self->flash( error => 'That account no longer exists.' );
            return $self->redirect_to('admin_people');
        }

        $user->reactivate( $dao->db );
        $self->flash( success =>
            sprintf( '%s can sign in again.', $user->name || $user->username ) );

        return $self->redirect_to('admin_people');
    }
}
