#!/usr/bin/env perl
# ABOUTME: Test UTF-8 handling in Registry workflow system
# ABOUTME: Ensures proper encoding in workflows, templates, and database storage

use 5.40.2;
use utf8;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More;
use Test::Mojo;
use Test::Registry::DB;

defer { done_testing };

# Set up test database
my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;

# Initialize test app with the test database
$ENV{DB_URL} = $test_db->uri;
my $t = Test::Mojo->new('Registry');

# UTF-8 test strings
my @test_strings = (
    'Café français',
    'Größe über älteren',
    'Niño español',
    '日本語テスト',
    '中文测试',
    'Тест кириллица',
    'مرحبا بالعالم',
    'שלום עולם',
    '😀🎉🌟',
);

subtest 'Template storage and retrieval with UTF-8' => sub {
    # Create template with UTF-8 content
    my $template_content = <<'TEMPLATE';
% layout 'workflow';
% title 'UTF-8 Test - テスト';
<h2>International Content - 国際コンテンツ</h2>
<p>French: Café français</p>
<p>German: Größe über älteren</p>
<p>Spanish: Niño español</p>
<p>Japanese: 日本語テスト</p>
<p>Chinese: 中文测试</p>
<p>Russian: Тест кириллица</p>
<p>Arabic: مرحبا بالعالم</p>
<p>Hebrew: שלום עולם</p>
<p>Emoji: 😀🎉🌟</p>
TEMPLATE

    my $template = $dao->create('Registry::DAO::Template' => {
        name    => 'test-utf8/display',
        slug    => 'test-utf8-display',
        content => $template_content,
    });

    ok($template, 'Template created');
    is($template->name, 'test-utf8/display', 'Template name correct');

    # Retrieve template and check content
    my ($retrieved) = $dao->find('Registry::DAO::Template' => { id => $template->id });
    ok($retrieved, 'Template retrieved');

    # Check that UTF-8 content is preserved
    for my $test_string (@test_strings) {
        like($retrieved->content, qr/\Q$test_string\E/, "Template content contains: $test_string");
    }
};

subtest 'Workflow with UTF-8 data' => sub {
    # Create workflow with UTF-8 name and description
    my $workflow = $dao->create('Registry::DAO::Workflow' => {
        name => 'Café Registration - 咖啡注册',
        slug => 'test-utf8-workflow',
        description => 'Test workflow for UTF-8: niño, café, 测试',
    });

    ok($workflow, 'Workflow created');
    is($workflow->name, 'Café Registration - 咖啡注册', 'UTF-8 name preserved');
    like($workflow->description, qr/niño, café, 测试/, 'UTF-8 description preserved');

    # Create workflow step with UTF-8 description
    my $step = Registry::DAO::WorkflowStep->create($dao->db, {
        workflow_id => $workflow->id,
        slug        => 'input',
        description => 'Entrée des données - 数据输入',
        class       => 'Registry::DAO::WorkflowStep',
    });

    ok($step, 'Step created');
    is($step->description, 'Entrée des données - 数据输入', 'UTF-8 step description preserved');

    # Update workflow with first step
    $dao->db->update(
        'workflows',
        { first_step => 'input' },
        { id => $workflow->id }
    );

    # Create and process run with UTF-8 data
    my $run = $workflow->new_run($dao->db);
    ok($run, 'Run created');

    my $utf8_data = {
        name => 'José García',
        café => 'Café Société',
        notes => '注意事項: テスト',
        emoji => '🎉🚀',
    };

    $run->process($dao->db, $step, $utf8_data);

    # Check data is preserved
    my $stored_data = $run->data;
    is($stored_data->{name}, 'José García', 'UTF-8 name in run data');
    is($stored_data->{café}, 'Café Société', 'UTF-8 café in run data');
    is($stored_data->{notes}, '注意事項: テスト', 'Japanese notes in run data');
    is($stored_data->{emoji}, '🎉🚀', 'Emoji in run data');
};

subtest 'Workflow rendering with UTF-8' => sub {
    # Create index template for workflow
    my $index_template = <<'TEMPLATE';
% layout 'default';
% title 'UTF-8 Render Test';
<h1>UTF-8 Render Test Workflow</h1>
<p>Test workflow for UTF-8 rendering</p>
<form method="POST" action="<%= $action %>">
    <button type="submit">Start Workflow</button>
</form>
TEMPLATE

    # Create index template
    my $index_tmpl = $dao->create('Registry::DAO::Template' => {
        name    => 'test-utf8-render/index',
        slug    => 'test-utf8-render-index',
        content => $index_template,
    });

    # Create template for workflow step
    my $form_template = <<'TEMPLATE';
% layout 'workflow';
% title 'UTF-8 Form - フォーム';
<h2>Registration Form - 登録フォーム</h2>
<form method="POST" action="<%= $action %>">
    <label>Name / 名前:</label>
    <input type="text" name="name" value="<%= $data_json ? do { my $d = Mojo::JSON::decode_json($data_json); $d->{name} // '' } : '' %>">

    <label>Café:</label>
    <input type="text" name="café" placeholder="e.g., Café français">

    <label>Notes / 備考:</label>
    <textarea name="notes" placeholder="注意事項..."></textarea>

    <button type="submit">Submit / 提出</button>
</form>
<p>Test strings: café, niño, größe, 测试, テスト</p>
TEMPLATE

    # Create template
    my $template = $dao->create('Registry::DAO::Template' => {
        name    => 'test-utf8-render/form',
        slug    => 'test-utf8-render-form',
        content => $form_template,
    });

    # Create workflow
    my $workflow = $dao->create('Registry::DAO::Workflow' => {
        name => 'UTF-8 Render Test',
        slug => 'test-utf8-render',
        first_step => 'form',  # Set first step here
    });

    # Create step with template
    my $step = Registry::DAO::WorkflowStep->create($dao->db, {
        workflow_id => $workflow->id,
        slug        => 'form',
        description => 'UTF-8 Form Step',
        class       => 'Registry::DAO::WorkflowStep',
    });

    $step->set_template($dao->db, $template);

    # Test rendering through controller
    $t->get_ok('/test-utf8-render');

    if ($t->tx->res->code != 200) {
        diag "Status: " . $t->tx->res->code;
        diag "Body: " . $t->tx->res->body;
    }

    $t->status_is(200, 'Workflow index page loads')
      ->content_type_like(qr/text\/html/);

    # Start workflow to get to form
    $t->post_ok('/test-utf8-render');

    if ($t->tx->res->code != 302) {
        diag "POST Status: " . $t->tx->res->code;
        diag "POST Body: " . $t->tx->res->body;
    }

    $t->status_is(302);

    my $location = $t->tx->res->headers->location;
    ok($location, 'Got redirect location');

    # Follow redirect to form
    $t->get_ok($location)
      ->status_is(200)
      ->content_type_like(qr/text\/html/)
      ->content_like(qr/UTF-8 Form - フォーム/, 'UTF-8 title present')
      ->content_like(qr/Registration Form - 登録フォーム/, 'UTF-8 heading present')
      ->content_like(qr/Name \/ 名前/, 'Japanese label present')
      ->content_like(qr/Café français/, 'French text in placeholder')
      ->content_like(qr/注意事項/, 'Japanese placeholder')
      ->content_like(qr/Submit \/ 提出/, 'Japanese button text')
      ->content_like(qr/café, niño, größe, 测试, テスト/, 'All test strings present');
};

subtest 'Form submission with UTF-8 through workflow' => sub {
    # Create index template for workflow
    my $index_template = <<'TEMPLATE';
% layout 'default';
% title 'UTF-8 Form Test';
<h1>UTF-8 Form Test</h1>
<form method="POST" action="<%= $action %>">
    <button type="submit">Start</button>
</form>
TEMPLATE

    # Create index template
    my $index_tmpl = $dao->create('Registry::DAO::Template' => {
        name    => 'test-utf8-form/index',
        slug    => 'test-utf8-form-index',
        content => $index_template,
    });

    # Create a simple workflow for form processing
    my $workflow = $dao->create('Registry::DAO::Workflow' => {
        name => 'UTF-8 Form Workflow',
        slug => 'test-utf8-form',
        first_step => 'input',  # Set first step here
    });

    # Create simple form template
    my $template = $dao->create('Registry::DAO::Template' => {
        name    => 'test-utf8-form/input',
        slug    => 'test-utf8-form-input',
        content => <<'TEMPLATE',
% layout 'workflow';
% title 'UTF-8 Input';
<form method="POST" action="<%= $action %>">
    <input type="text" name="name" placeholder="Name">
    <input type="text" name="city" placeholder="City">
    <textarea name="notes" placeholder="Notes"></textarea>
    <button type="submit">Submit</button>
</form>
TEMPLATE
    });

    # Create input step
    my $input_step = Registry::DAO::WorkflowStep->create($dao->db, {
        workflow_id => $workflow->id,
        slug        => 'input',
        description => 'Input Step',
        class       => 'Registry::DAO::WorkflowStep',
    });

    $input_step->set_template($dao->db, $template);

    # Start workflow
    $t->post_ok('/test-utf8-form')
      ->status_is(302);

    my $location = $t->tx->res->headers->location;
    my ($run_id) = $location =~ m{/test-utf8-form/(\d+)/};
    ok($run_id, 'Got run ID');

    # Submit form with UTF-8 data
    my $utf8_data = {
        name => 'François Müller',
        city => '東京 (Tokyo)',
        notes => 'Test notes: café, niño, größe, 测试, テスト, 🎉',
    };

    $t->post_ok("/test-utf8-form/$run_id/input" => form => $utf8_data)
      ->status_is(201);

    # Verify data in database
    my ($run) = $dao->find('WorkflowRun' => { id => $run_id });
    ok($run, 'Found run');

    my $data = $run->data;
    is($data->{name}, 'François Müller', 'UTF-8 name stored');
    is($data->{city}, '東京 (Tokyo)', 'Japanese city stored');
    like($data->{notes}, qr/café, niño, größe, 测试, テスト, 🎉/, 'All UTF-8 characters in notes');
};

done_testing;