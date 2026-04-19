use 5.42.0;
# ABOUTME: Workflow step that attaches a contact person to the pending
# ABOUTME: location and commits it. Accepts an existing user or creates one inline.

use Object::Pad;

class Registry::DAO::WorkflowSteps::LocationContact :isa(Registry::DAO::WorkflowStep) {

use Registry::DAO::Location;
use Registry::DAO::User;

method process ($db, $form_data, $run = undef) {
    $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };

    return { stay => 1 } unless exists $form_data->{contact_mode};

    my $pending = $run->data->{location_pending};
    return { errors => ['Missing location details; restart the workflow.'] }
        unless $pending && ref $pending eq 'HASH';

    my ($contact_id, @errors);

    if (($form_data->{contact_mode} // '') eq 'existing') {
        my $id = $form_data->{contact_id} // '';
        my $user = $id
            ? Registry::DAO::User->find($db, { id => $id })
            : undef;
        push @errors, 'Selected contact person does not exist' unless $user;
        $contact_id = $user->id if $user;
    }
    elsif (($form_data->{contact_mode} // '') eq 'new') {
        my $name  = $form_data->{contact_name}  // '';
        my $email = $form_data->{contact_email} // '';
        push @errors, 'Contact name is required'  unless length $name;
        push @errors, 'Contact email is required' unless length $email;

        unless (@errors) {
            my $username = lc($email =~ s/[^a-z0-9_]+/_/gir);
            my $user = eval {
                Registry::DAO::User->create($db, {
                    name      => $name,
                    username  => $username,
                    email     => $email,
                    user_type => 'staff',
                    password  => '',
                });
            };
            if (my $e = $@) {
                push @errors, "Failed to create contact user: $e";
            }
            else {
                $contact_id = $user->id;
            }
        }
    }
    else {
        push @errors, 'Choose an existing contact or enter new-user details';
    }

    return { errors => \@errors } if @errors;

    my %data = %$pending;
    $data{contact_person_id} = $contact_id;

    my $editing_id = $run->data->{editing_location_id};
    if ($editing_id) {
        my $existing = Registry::DAO::Location->find($db, { id => $editing_id });
        return { errors => ['Location no longer exists'] } unless $existing;
        $existing->update($db, \%data);
    }
    else {
        Registry::DAO::Location->create($db, \%data);
    }

    # Clear pending state on success.
    $run->update_data($db, {
        location_pending     => undef,
        editing_location_id  => undef,
    });

    return { next_step => 'complete' };
}

method prepare_template_data ($db, $run, $params = {}) {
    # Offer staff + admin users as candidates for contact person.
    my $raw = $db isa Registry::DAO ? $db->db : $db;
    my $rows = $raw->query(
        q{SELECT u.id, up.name, up.email
          FROM users u
          JOIN user_profiles up ON up.user_id = u.id
          WHERE u.user_type IN ('admin', 'staff')
          ORDER BY up.name}
    )->hashes->to_array;

    my $pending = $run->data->{location_pending} // {};

    return {
        candidates    => $rows,
        pending_name  => $pending->{name} // '',
    };
}

}
