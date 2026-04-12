#!/usr/bin/env perl
# ABOUTME: Tests that WorkflowStep and Template metadata fields work correctly.
# ABOUTME: Validates #152 - metadata reader accessibility and null handling.

use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw(done_testing is is_deeply ok subtest)];
defer { done_testing };

use Test::Registry::DB;
use Registry::DAO::WorkflowStep;
use Registry::DAO::Template;

my $test_db = Test::Registry::DB->new;
my $dao = $test_db->db;

subtest 'WorkflowStep metadata is accessible via reader' => sub {
    # Import a workflow so we have steps to query
    $dao->import_workflows(['workflows/tenant-signup.yml']);

    my @steps = Registry::DAO::WorkflowStep->find($dao->db, {});
    ok @steps > 0, 'Found workflow steps';

    my $step = $steps[0];
    # The metadata field should be accessible via a reader method
    ok $step->can('metadata'), 'WorkflowStep has metadata reader method';

    my $meta = $step->metadata;
    ok defined $meta, 'metadata returns a defined value';
    is ref($meta), 'HASH', 'metadata is a hashref (decoded from jsonb by expand)';
};

subtest 'WorkflowStep metadata defaults to empty hash for null DB values' => sub {
    # Insert a step row with explicit NULL metadata to test the ADJUST coercion
    my $workflow = $dao->find('Registry::DAO::Workflow', { slug => 'tenant-signup' });
    ok $workflow, 'Found workflow';

    $dao->db->insert('workflow_steps', {
        workflow_id => $workflow->id,
        slug        => 'null-meta-test',
        description => 'test step with null metadata',
        metadata    => undef,
        class       => 'Registry::DAO::WorkflowStep',
    });

    my $step = Registry::DAO::WorkflowStep->find($dao->db, { slug => 'null-meta-test' });
    ok $step, 'Found step with null metadata';
    is ref($step->metadata), 'HASH', 'null metadata coerced to empty hashref';
};

subtest 'Template metadata is accessible and null-safe' => sub {
    # Create a template with no metadata to test null coercion
    my $tmpl = Registry::DAO::Template->create($dao->db, {
        name    => 'meta-test/example',
        slug    => 'meta-test-example',
        content => '<p>test</p>',
    });
    ok $tmpl, 'Created template';

    ok $tmpl->can('metadata'), 'Template has metadata reader method';
    my $meta = $tmpl->metadata;
    ok defined $meta, 'metadata returns a defined value';
    is ref($meta), 'HASH', 'metadata is a hashref (null coerced to {})';
};
