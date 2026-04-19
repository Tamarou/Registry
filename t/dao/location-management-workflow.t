#!/usr/bin/env perl
# ABOUTME: DAO-level tests for the location-management workflow steps.
# ABOUTME: Covers list/create/edit with contact-person selection or inline create.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'keyword_any';
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::Location;
use Registry::DAO::User;

my $tdb = Test::Registry::DB->new;
my $dao = $tdb->db;

my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Location Mgmt Tenant',
    slug => 'loc_mgmt',
});
$dao->db->query('SELECT clone_schema(?)', 'loc_mgmt');
$dao = Registry::DAO->new(url => $tdb->uri, schema => 'loc_mgmt');
my $db = $dao->db;

# Seed a user and a location to exercise edit and dropdown paths.
my $existing_user = Registry::DAO::User->create($db, {
    name      => 'Existing Contact',
    username  => 'existing_contact',
    email     => 'contact@test.local',
    user_type => 'staff',
    password  => 'x',
});

my $seeded_location = Registry::DAO::Location->create($db, {
    name              => 'Dr Phillips Elementary',
    address_info      => { city => 'Orlando' },
    capacity          => 25,
    contact_person_id => $existing_user->id,
});

# Build the workflow matching the YAML we'll ship.
my $workflow = Registry::DAO::Workflow->create($db, {
    name        => 'Location Management',
    slug        => 'location-management',
    description => 'Manage locations',
    first_step  => 'list-or-create',
});
$workflow->add_step($db, {
    slug        => 'list-or-create',
    description => 'List existing locations or start a new one',
    class       => 'Registry::DAO::WorkflowSteps::LocationList',
});
$workflow->add_step($db, {
    slug        => 'location-details',
    description => 'Name, address, capacity',
    class       => 'Registry::DAO::WorkflowSteps::LocationDetails',
});
$workflow->add_step($db, {
    slug        => 'select-contact',
    description => 'Pick the contact person for this location',
    class       => 'Registry::DAO::WorkflowSteps::LocationContact',
});
$workflow->add_step($db, {
    slug        => 'complete',
    description => 'Done',
    class       => 'Registry::DAO::WorkflowStep',
});

subtest 'list step shows existing locations' => sub {
    require_ok 'Registry::DAO::WorkflowSteps::LocationList';

    my $step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id, slug => 'list-or-create',
    });
    my $run = $workflow->new_run($db);

    my $data = $step->prepare_template_data($db, $run);
    ok($data->{locations}, 'locations returned');
    is(scalar @{$data->{locations}}, 1, 'one seeded location');
    is($data->{locations}[0]->name, 'Dr Phillips Elementary', 'correct name');
};

subtest 'list step Create New advances to details with no editing id' => sub {
    my $step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id, slug => 'list-or-create',
    });
    my $run = $workflow->new_run($db);

    my $result = $step->process($db, { action => 'new' }, $run);
    is($result->{next_step}, 'location-details', 'advances to details');
};

subtest 'list step Edit picks an existing location by id' => sub {
    my $step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id, slug => 'list-or-create',
    });
    my $run = $workflow->new_run($db);

    my $result = $step->process($db, {
        action => 'edit', id => $seeded_location->id,
    }, $run);
    is($result->{next_step}, 'location-details', 'advances to details');
    is($run->data->{editing_location_id}, $seeded_location->id,
       'editing_location_id stored in run data');
};

subtest 'list step rejects edit of unknown id' => sub {
    my $step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id, slug => 'list-or-create',
    });
    my $run = $workflow->new_run($db);

    my $result = $step->process($db, {
        action => 'edit', id => '00000000-0000-0000-0000-000000000000',
    }, $run);
    ok($result->{stay}, 'stays on step for unknown id');
    ok($result->{errors}, 'returns errors');
};

subtest 'details step validates required fields' => sub {
    require_ok 'Registry::DAO::WorkflowSteps::LocationDetails';

    my $step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id, slug => 'location-details',
    });
    my $run = $workflow->new_run($db);

    my $result = $step->process($db, { name => '' }, $run);
    ok($result->{errors}, 'returns errors when name missing');
    ok((any { /name/i } @{$result->{errors}}), 'error mentions name');
};

subtest 'details step stores form data in run data for next step' => sub {
    my $step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id, slug => 'location-details',
    });
    my $run = $workflow->new_run($db);

    my $result = $step->process($db, {
        name           => 'New Studio',
        street_address => '123 Art Way',
        city           => 'Orlando',
        state          => 'FL',
        postal_code    => '32819',
        capacity       => 15,
    }, $run);

    ok(!$result->{errors}, 'no errors') or diag(explain($result));
    is($result->{next_step}, 'select-contact', 'advances to contact step');

    my $pending = $run->data->{location_pending};
    ok($pending, 'pending location payload stored');
    is($pending->{name}, 'New Studio', 'name carried forward');
    is($pending->{address_info}{city}, 'Orlando', 'address_info carried');
    is($pending->{capacity}, 15, 'capacity carried');
};

subtest 'details step pre-populates form when editing' => sub {
    my $step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id, slug => 'location-details',
    });
    my $run = $workflow->new_run($db);
    $run->update_data($db, { editing_location_id => $seeded_location->id });

    my $data = $step->prepare_template_data($db, $run);
    is($data->{name}, 'Dr Phillips Elementary', 'name pre-filled');
    is($data->{city}, 'Orlando', 'city pre-filled');
    is($data->{capacity}, 25, 'capacity pre-filled');
    ok($data->{editing}, 'editing flag set');
};

subtest 'contact step picks an existing user and creates the location' => sub {
    require_ok 'Registry::DAO::WorkflowSteps::LocationContact';

    my $step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id, slug => 'select-contact',
    });
    my $run = $workflow->new_run($db);
    $run->update_data($db, {
        location_pending => {
            name         => 'Studio A',
            slug         => 'studio_a',
            address_info => { city => 'Orlando' },
            capacity     => 10,
        },
    });

    my $result = $step->process($db, {
        contact_mode => 'existing',
        contact_id   => $existing_user->id,
    }, $run);
    ok(!$result->{errors}, 'no errors on existing-user path')
        or diag(explain($result));
    is($result->{next_step}, 'complete', 'advances to complete');

    my $created = Registry::DAO::Location->find($db, { name => 'Studio A' });
    ok($created, 'location created in DB');
    is($created->contact_person_id, $existing_user->id,
       'contact_person_id set to the existing user');
};

subtest 'contact step creates a new user inline when asked' => sub {
    my $step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id, slug => 'select-contact',
    });
    my $run = $workflow->new_run($db);
    $run->update_data($db, {
        location_pending => {
            name         => 'Studio B',
            slug         => 'studio_b',
            address_info => {},
            capacity     => 8,
        },
    });

    my $result = $step->process($db, {
        contact_mode  => 'new',
        contact_name  => 'Brand New Person',
        contact_email => 'brandnew@test.local',
    }, $run);
    ok(!$result->{errors}, 'no errors on new-user path')
        or diag(explain($result));
    is($result->{next_step}, 'complete', 'advances to complete');

    my $created_loc = Registry::DAO::Location->find($db, { name => 'Studio B' });
    ok($created_loc, 'location created');
    my $new_user = Registry::DAO::User->find($db, { email => 'brandnew@test.local' });
    ok($new_user, 'new user created inline');
    is($created_loc->contact_person_id, $new_user->id,
       'location links to the newly-created user');
};

subtest 'contact step surfaces friendly error when email already exists' => sub {
    my $step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id, slug => 'select-contact',
    });
    my $run = $workflow->new_run($db);
    $run->update_data($db, {
        location_pending => { name => 'Studio D', slug => 'studio_d',
                              address_info => {}, capacity => 5 },
    });

    my $result = $step->process($db, {
        contact_mode  => 'new',
        contact_name  => 'Another Person',
        contact_email => $existing_user->email,
    }, $run);
    ok($result->{errors}, 'rejects duplicate email');
    ok((any { /already exists/i } @{$result->{errors}}),
       'error mentions existing user');
};

subtest 'contact step rejects new-user without required fields' => sub {
    my $step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id, slug => 'select-contact',
    });
    my $run = $workflow->new_run($db);
    $run->update_data($db, {
        location_pending => { name => 'Studio C', slug => 'studio_c',
                              address_info => {}, capacity => 1 },
    });

    my $result = $step->process($db, {
        contact_mode => 'new',
        # name and email missing
    }, $run);
    ok($result->{errors}, 'rejects missing new-user fields');
};

subtest 'editing a location updates it and keeps the same row' => sub {
    my $details_step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id, slug => 'location-details',
    });
    my $contact_step = Registry::DAO::WorkflowStep->find($db, {
        workflow_id => $workflow->id, slug => 'select-contact',
    });

    my $run = $workflow->new_run($db);
    $run->update_data($db, { editing_location_id => $seeded_location->id });

    $details_step->process($db, {
        name     => 'Dr Phillips Elementary (Renamed)',
        city     => 'Orlando',
        capacity => 30,
    }, $run);
    $contact_step->process($db, {
        contact_mode => 'existing',
        contact_id   => $existing_user->id,
    }, $run);

    my $updated = Registry::DAO::Location->find($db, { id => $seeded_location->id });
    is($updated->name, 'Dr Phillips Elementary (Renamed)', 'name updated');
    is($updated->capacity, 30, 'capacity updated');
};

done_testing();
