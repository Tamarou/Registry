#!/usr/bin/env perl
# ABOUTME: Test UTF-8 handling in Registry workflow system
# ABOUTME: Ensures proper encoding in workflows, templates, and database storage

use 5.42.0;
use utf8;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More;
use Test::Mojo;
use Test::Registry::DB;


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

# Note: Additional integration tests for workflow rendering would require
# full workflow controller setup, which is beyond the scope of UTF-8 testing.
# The database storage and retrieval tests above verify that UTF-8 works
# correctly in the core workflow data handling.

done_testing;