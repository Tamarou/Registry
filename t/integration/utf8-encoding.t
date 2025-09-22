#!/usr/bin/env perl
# ABOUTME: Test UTF-8 character handling in workflows and templates
# ABOUTME: Ensures proper encoding/decoding of non-ASCII characters

use 5.40.2;
use utf8;
use Test::More;
use Test::Mojo;
use Mojo::File qw(path);

# Skip test if database is not available
BEGIN {
    plan skip_all => 'Database tests require DB_URL environment variable'
        unless $ENV{DB_URL};
}

use Registry::DAO;

# Initialize test application
my $t = Test::Mojo->new('Registry');

# Use test database URL from environment
my $test_schema = 'test_utf8_' . $$;  # Use PID to make schema unique
my $dao = Registry::DAO->new(
    url    => $ENV{DB_URL},
    schema => $test_schema
);

# Create test schema
eval {
    $dao->db->query("CREATE SCHEMA IF NOT EXISTS $test_schema");
    $dao->db->query("SET search_path TO $test_schema");

    # Deploy schema using the test schema
    my $cmd = "carton exec sqitch deploy --target db:pg: --to-change schema 2>&1";
    my $output = `$cmd`;
    if ($? != 0) {
        die "Sqitch deploy failed: $output";
    }
};
if ($@) {
    plan skip_all => "Failed to set up test database: $@";
}

# Test UTF-8 characters from various languages
my @test_strings = (
    'Café français',           # French
    'Größe über älteren',      # German
    'Niño español',            # Spanish
    '日本語テスト',             # Japanese
    '中文测试',                # Chinese
    'Тест кириллица',          # Russian
    'مرحبا بالعالم',           # Arabic
    'שלום עולם',              # Hebrew
    'Emoji test 😀🎉🌟',       # Emojis
);

subtest 'Template rendering with UTF-8' => sub {
    # Create a test template with UTF-8 content
    my $template_content = <<'TEMPLATE';
% layout 'workflow';
% title 'UTF-8 Test Page';
<h2>International Content Test</h2>
<p>French: Café français</p>
<p>German: Größe über älteren</p>
<p>Spanish: Niño español</p>
<p>Japanese: 日本語テスト</p>
<p>Chinese: 中文测试</p>
<p>Russian: Тест кириллица</p>
<p>Arabic: مرحبا بالعالم</p>
<p>Hebrew: שלום עולם</p>
<p>Emoji: 😀🎉🌟</p>
<%= stash('dynamic_content') || '' %>
TEMPLATE

    # Create test template in database
    my $template = $dao->create('Registry::DAO::Template' => {
        name    => 'test-utf8/display',
        slug    => 'test-utf8-display',
        content => $template_content,
    });

    # Create workflow for UTF-8 testing
    my $workflow = $dao->create('Registry::DAO::Workflow' => {
        name => 'Test UTF-8 Workflow',
        slug => 'test-utf8',
    });

    # Create workflow step
    my $step = Registry::DAO::WorkflowStep->create($dao->db, {
        workflow_id => $workflow->id,
        slug        => 'display',
        description => 'UTF-8 Display Test Step',
        class       => 'Registry::DAO::WorkflowStep',
    });

    # Set template for the step
    $step->set_template($dao->db, $template);

    # Update workflow with first step
    $dao->db->update(
        'workflows',
        { first_step => 'display' },
        { id => $workflow->id }
    );

    # Test rendering the template
    $t->get_ok('/test-utf8')
      ->status_is(200)
      ->content_type_like(qr/text\/html/);

    # Check that UTF-8 characters are properly displayed
    for my $test_string (@test_strings) {
        $t->content_like(qr/\Q$test_string\E/, "Template contains: $test_string");
    }
};

subtest 'Form submission with UTF-8' => sub {
    # Create a form template with UTF-8 input fields
    my $form_template = <<'TEMPLATE';
% layout 'workflow';
% title 'UTF-8 Form Test';
<h2>Submit UTF-8 Content</h2>
<form method="POST" action="<%= $action %>">
    <div>
        <label for="name">Name (with accents):</label>
        <input type="text" id="name" name="name" value="<%= stash('name') || '' %>">
    </div>
    <div>
        <label for="description">Description (multilingual):</label>
        <textarea id="description" name="description"><%= stash('description') || '' %></textarea>
    </div>
    <button type="submit">Submit</button>
</form>
TEMPLATE

    # Create form template
    my $form_template_obj = $dao->create('Registry::DAO::Template' => {
        name    => 'test-utf8-form/input',
        slug    => 'test-utf8-form-input',
        content => $form_template,
    });

    # Create workflow for form testing
    my $form_workflow = $dao->create('Registry::DAO::Workflow' => {
        name => 'Test UTF-8 Form Workflow',
        slug => 'test-utf8-form',
    });

    # Create workflow step
    my $form_step = Registry::DAO::WorkflowStep->create($dao->db, {
        workflow_id => $form_workflow->id,
        slug        => 'input',
        description => 'UTF-8 Form Input Step',
        class       => 'Registry::DAO::WorkflowStep',
    });

    $form_step->set_template($dao->db, $form_template_obj);

    # Update workflow with first step
    $dao->db->update(
        'workflows',
        { first_step => 'input' },
        { id => $form_workflow->id }
    );

    # Start workflow
    $t->post_ok('/test-utf8-form')
      ->status_is(302);

    # Get the redirect location
    my $location = $t->tx->res->headers->location;
    ok($location, 'Got redirect location');

    # Extract run ID from location
    my ($run_id) = $location =~ m{/test-utf8-form/(\d+)/};
    ok($run_id, 'Extracted run ID');

    # Submit form with UTF-8 data
    my $utf8_name = 'José María García-López';
    my $utf8_description = "Descripción con acentos: niño, señora, café.\nJapanese: 日本語\nEmoji: 🎉";

    $t->post_ok("/test-utf8-form/$run_id/input", form => {
        name => $utf8_name,
        description => $utf8_description,
    })->status_is(201, 'Form submission successful');

    # Verify data was stored correctly
    my $run = ($dao->find('WorkflowRun' => { id => $run_id }))[0];
    ok($run, 'Found workflow run');

    my $data = $run->data || {};
    is($data->{name}, $utf8_name, 'UTF-8 name stored correctly');
    is($data->{description}, $utf8_description, 'UTF-8 description stored correctly');
};

subtest 'Dynamic content with UTF-8' => sub {
    # Test that dynamically generated content handles UTF-8 properly

    # Create outcome definition with UTF-8 labels
    my $outcome_def = Registry::DAO::OutcomeDefinition->create($dao->db, {
        name => 'UTF-8 Test Form',
        schema => {
            type => 'object',
            properties => {
                café_name => {
                    type => 'string',
                    title => 'Café Name (Français)',
                    description => 'Entrez le nom du café',
                },
                größe => {
                    type => 'number',
                    title => 'Größe (Deutsch)',
                    description => 'Die Größe eingeben',
                },
                niño_age => {
                    type => 'number',
                    title => 'Edad del Niño (Español)',
                    description => 'Ingrese la edad del niño',
                }
            }
        }
    });

    # Create dynamic template
    my $dynamic_template = <<'TEMPLATE';
% layout 'workflow';
% title 'Dynamic UTF-8 Test';
<h2>Dynamic Content with UTF-8</h2>
<div id="outcome-form" data-outcome-id="<%= $outcome_definition_id %>">
    Loading form...
</div>
<script>
    // Fetch and display outcome definition
    fetch('/api/outcome-definitions/<%= $outcome_definition_id %>')
        .then(response => response.json())
        .then(schema => {
            // Display the schema properties with UTF-8 labels
            const formDiv = document.getElementById('outcome-form');
            let html = '<form>';
            for (const [key, prop] of Object.entries(schema.properties || {})) {
                html += `
                    <div>
                        <label>${prop.title || key}</label>
                        <p>${prop.description || ''}</p>
                        <input type="${prop.type === 'number' ? 'number' : 'text'}" name="${key}">
                    </div>
                `;
            }
            html += '</form>';
            formDiv.innerHTML = html;
        });
</script>
TEMPLATE

    # Create template
    my $dynamic_template_obj = $dao->create('Registry::DAO::Template' => {
        name    => 'test-utf8-dynamic/form',
        slug    => 'test-utf8-dynamic-form',
        content => $dynamic_template,
    });

    # Create workflow
    my $dynamic_workflow = $dao->create('Registry::DAO::Workflow' => {
        name => 'Test UTF-8 Dynamic Workflow',
        slug => 'test-utf8-dynamic',
    });

    # Create workflow step with outcome definition
    my $dynamic_step = Registry::DAO::WorkflowStep->create($dao->db, {
        workflow_id => $dynamic_workflow->id,
        slug        => 'form',
        description => 'UTF-8 Dynamic Form Step',
        class       => 'Registry::DAO::WorkflowStep',
        outcome_definition_id => $outcome_def->id,
    });

    $dynamic_step->set_template($dao->db, $dynamic_template_obj);

    # Update workflow with first step
    $dao->db->update(
        'workflows',
        { first_step => 'form' },
        { id => $dynamic_workflow->id }
    );

    # Start workflow and get form
    $t->post_ok('/test-utf8-dynamic')
      ->status_is(302);

    my $location = $t->tx->res->headers->location;
    my ($run_id) = $location =~ m{/test-utf8-dynamic/(\d+)/};

    $t->get_ok("/test-utf8-dynamic/$run_id/form")
      ->status_is(200)
      ->content_type_like(qr/text\/html/)
      ->content_like(qr/Dynamic Content with UTF-8/, 'Page title present');

    # Test outcome definition API endpoint
    $t->get_ok("/api/outcome-definitions/" . $outcome_def->id)
      ->status_is(200)
      ->content_type_like(qr/application\/json/)
      ->json_has('/properties/café_name/title')
      ->json_is('/properties/café_name/title', 'Café Name (Français)')
      ->json_is('/properties/größe/title', 'Größe (Deutsch)')
      ->json_is('/properties/niño_age/title', 'Edad del Niño (Español)');
};

subtest 'Workflow step descriptions with UTF-8' => sub {
    # Test that workflow step descriptions handle UTF-8

    my $intl_workflow = $dao->create('Registry::DAO::Workflow' => {
        name => 'International Workflow',
        slug => 'intl-workflow',
    });

    my @intl_steps = (
        { slug => 'café', description => 'Sélectionnez votre café préféré' },
        { slug => 'größe', description => 'Wählen Sie die Größe' },
        { slug => 'niño', description => 'Información del niño' },
        { slug => '日本', description => '日本語のステップ' },
    );

    for my $step_data (@intl_steps) {
        my $step = Registry::DAO::WorkflowStep->create($dao->db, {
            workflow_id => $intl_workflow->id,
            slug        => $step_data->{slug},
            description => $step_data->{description},
            class       => 'Registry::DAO::WorkflowStep',
        });

        ok($step, "Created step with slug: $step_data->{slug}");
        is($step->description, $step_data->{description},
           "Step description preserved: $step_data->{description}");
    }

    # Verify descriptions are stored correctly in database
    my $steps_from_db = $dao->db->select(
        'workflow_steps',
        ['slug', 'description'],
        { workflow_id => $intl_workflow->id }
    )->hashes;

    for my $db_step (@$steps_from_db) {
        my ($original) = grep { $_->{slug} eq $db_step->{slug} } @intl_steps;
        is($db_step->{description}, $original->{description},
           "Database preserved UTF-8 for step: $db_step->{slug}");
    }
};

# Cleanup
END {
    if ($dao && $dao->db && $test_schema) {
        eval { $dao->db->query("DROP SCHEMA IF EXISTS $test_schema CASCADE"); };
    }
}

done_testing;