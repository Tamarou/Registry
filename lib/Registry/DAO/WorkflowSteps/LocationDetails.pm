use 5.42.0;
# ABOUTME: Workflow step that collects location details (name, address, capacity).
# ABOUTME: Stores the pending payload in run data; LocationContact finalises it.

use Object::Pad;

class Registry::DAO::WorkflowSteps::LocationDetails :isa(Registry::DAO::WorkflowStep) {

use Registry::DAO::Location;

method process ($db, $form_data, $run = undef) {
    $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };

    return { stay => 1 } unless exists $form_data->{name};

    my @errors;
    push @errors, 'Location name is required'
        unless defined $form_data->{name} && length $form_data->{name};

    if (defined $form_data->{capacity} && length $form_data->{capacity}) {
        unless ($form_data->{capacity} =~ /\A\d+\z/ && $form_data->{capacity} + 0 >= 1) {
            push @errors, 'Capacity must be a positive integer';
        }
    }

    return { errors => \@errors } if @errors;

    my %address_info;
    for my $field (qw(street_address city state postal_code country unit)) {
        $address_info{$field} = $form_data->{$field}
            if defined $form_data->{$field} && length $form_data->{$field};
    }

    my %pending = (
        name         => $form_data->{name},
        address_info => \%address_info,
    );
    $pending{capacity} = $form_data->{capacity} + 0
        if defined $form_data->{capacity} && length $form_data->{capacity};

    $run->update_data($db, { location_pending => \%pending });

    return { next_step => 'select-contact' };
}

method prepare_template_data ($db, $run, $params = {}) {
    my $id = $run->data->{editing_location_id};
    if ($id) {
        my $loc = Registry::DAO::Location->find($db, { id => $id });
        if ($loc) {
            my $addr = $loc->address_info // {};
            return {
                editing        => 1,
                name           => $loc->name,
                street_address => $addr->{street_address} // '',
                city           => $addr->{city}           // '',
                state          => $addr->{state}          // '',
                postal_code    => $addr->{postal_code}    // '',
                capacity       => $loc->capacity,
            };
        }
    }

    return {
        editing        => 0,
        name           => '',
        street_address => '',
        city           => '',
        state          => '',
        postal_code    => '',
        capacity       => '',
    };
}

}
