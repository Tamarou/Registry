use v5.38.2;
use utf8;
use Object::Pad;

use Registry::DAO::Workflow;

class Registry::DAO::RegisterCustomer : isa(Registry::DAO::WorkflowStep) {

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my $run = $workflow->latest_run($db);

        # TODO this should be data from a continuation not created here
        my $user_data = $run->data->{users};

        # TODO this should be a singl query not a loop
        my @users =
          map { Registry::DAO::User->find_or_create( $db, $_ ) } $user_data->@*;

        my $profile = $run->data;
        delete $profile->{users};    # TODO clean this up in the workflow
        $profile->{primary_user_id} = $users[0]->id;

        my $customer = Registry::DAO::Customer->create( $db, $profile );

        $customer->add_user( $db, $_ ) for @users;

        $db->query( 'SELECT clone_schema(dest_schema => ?)', $customer->slug );

        $db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)',
            $customer->slug, $_->id )
          for @users;

        if ( $run->has_continuation ) {
            my ($continuation) = $run->continuation($db);
            my $customers = $continuation->data->{customers} // [];
            push $customers->@*, $customer->id;
            $continuation->update_data( $db, { customers => $customers } );
        }

        # return the data to be stored in the workflow run
        return { customer => $customer->id };
    }
}

class Registry::DAO::CreateEvent : isa(Registry::DAO::WorkflowStep) {

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my ($run)      = $workflow->latest_run($db);
        my $data       = $run->data;

        # grab stuff that might have come from a continuation
        if ( $data->{locations} ) {
            $data->{location_id} //= $data->{locations}->[0];
        }

        if ( $data->{users} ) {
            $data->{teacher_id} //= $data->{users}->[0];
        }

        if ( $data->{projects} ) {
            $data->{project_id} //= $data->{projects}->[0];
        }

        # only include keys that have values
        my @keys = grep $data->{$_} => qw(
          time
          duration
          location_id
          project_id
          teacher_id
          metadata
          notes
        );

        my $event = Registry::DAO::Event->create( $db, { $data->%{@keys}, } );

        if ( $run->has_continuation ) {
            my ($continuation) = $run->continuation($db);
            my $events = $continuation->data->{events} // [];
            push $events->@*, $event->id;
            $continuation->update_data( $db, { events => $events } );
        }

        return { event => $event->id };
    }
}

class Registry::DAO::CreateSession : isa(Registry::DAO::WorkflowStep) {

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my ($run)      = $workflow->latest_run($db);

        my $data   = $run->data;
        my $events = $data->{events};

        # Mojolicious unwinds form posts of only one value
        $events = [$events] unless ref $events eq 'ARRAY';

        my $session = Registry::DAO::Session->create( $db,
            { $data->%{ 'name', 'metadata', 'notes' } } );
        $session->add_events( $db, $events->@* );

        if ( $run->has_continuation ) {
            my ($continuation) = $run->continuation($db);
            my $sessions = $continuation->data->{sessions} // [];
            push $sessions->@*, $session->id;
            $continuation->update_data( $db, { sessions => $sessions } );
        }

        return { session => $session->id };
    }
}
