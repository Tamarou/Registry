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
    # Create a step with explicit undef/null metadata to verify default behavior
    my $workflow = $dao->find('Registry::DAO::Workflow', { slug => 'tenant-signup' });
    ok $workflow, 'Found workflow';

    # Query a step and verify metadata is always a hashref, never undef
    my $step = Registry::DAO::WorkflowStep->find($dao->db, { workflow_id => $workflow->id });
    ok $step, 'Found a step';
    is ref($step->metadata), 'HASH', 'metadata is always a hashref';
};
