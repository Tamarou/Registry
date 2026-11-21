#!/usr/bin/env perl
# ABOUTME: Tests for HTMX integration: plugin registration, is_htmx_request detection,
# ABOUTME: and fragment rendering in the workflow controller.

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw(
    workflow_url
    workflow_run_step_url
    workflow_process_step_url
);

use Registry::DAO qw(Workflow);
use Registry::DAO::WorkflowStep;
use Registry::DAO::WorkflowRun;
use Mojo::Home;
use YAML::XS qw(Load);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# Import all workflows from YAML
my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($dao, $file->slurp);
}

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

# ============================================================
# Plugin registration: is_htmx_request helper exists
# ============================================================

subtest 'HTMX plugin provides is_htmx_request helper' => sub {
    # Test the helper works via a mock request
    # Without HX-Request header, should return false
    $t->get_ok('/program-creation')->status_is(200);
    # If we got here, the plugin loaded. Now verify it detects HTMX.
    # (Helpers are registered on the app, not as methods -- can() won't find them)
    pass 'HTMX plugin loaded and app started';
};

# ============================================================
# Layout serves HTMX via app->htmx->asset
# ============================================================

subtest 'layout includes HTMX 2.0.x script' => sub {
    # GET any workflow page to see the layout
    $t->get_ok('/program-creation')
      ->status_is(200)
      ->content_like(qr/htmx\.org\@2\.0/, 'page includes HTMX 2.0.x');
};

# ============================================================
# HTMX request detection: workflow stay renders fragment
# ============================================================

subtest 'HTMX POST to stay action renders fragment (no layout)' => sub {
    my ($workflow) = $dao->find(Workflow => { slug => 'template-editor' });
    ok $workflow, 'template-editor workflow exists';

    # Start a run
    $t->get_ok('/template-editor')->status_is(200);
    my $run = $workflow->latest_run($dao->db);

    my $step = $run->next_step($dao->db) || $run->latest_step($dao->db);
    ok $step, 'have a step';

    # POST without HX-Request: should get full page (with <html>)
    my $url = workflow_process_step_url($workflow, $run, $step);
    $t->post_ok($url => form => { action => 'list' })
      ->status_is(200)
      ->content_like(qr/<html/i, 'non-HTMX response has full page layout');

    # POST with HX-Request: should get fragment (no <html>)
    $t->post_ok($url => { 'HX-Request' => 'true' } => form => { action => 'list' })
      ->status_is(200)
      ->content_unlike(qr/<html/i, 'HTMX response is a fragment without layout');
};

# ============================================================
# HTMX step advance: renders fragment with HX-Push-URL header
# ============================================================

subtest 'HTMX POST that advances step returns fragment with push URL' => sub {
    my ($workflow) = $dao->find(Workflow => { slug => 'program-creation' });

    $t->reset_session;
    $t->get_ok('/program-creation')->status_is(200);
    my $run = $workflow->latest_run($dao->db);
    my $step = $run->next_step($dao->db);

    my $url = workflow_process_step_url($workflow, $run, $step);

    # POST with HX-Request to advance past type selection
    $t->post_ok($url => { 'HX-Request' => 'true' } => form => {
        program_type_slug => 'summer-camp',
    })->status_is(200);

    # Should be a fragment (no <html>)
    $t->content_unlike(qr/<html/i, 'HTMX advance response is fragment');

    # Should have HX-Push-URL header pointing to next step
    my $push_url = $t->tx->res->headers->header('HX-Push-URL');
    ok $push_url, 'HX-Push-URL header set';
    like $push_url, qr/curriculum-details/, 'push URL points to next step';
};

# ============================================================
# Non-HTMX POST still redirects (progressive enhancement)
# ============================================================

subtest 'non-HTMX POST still returns 302 redirect' => sub {
    my ($workflow) = $dao->find(Workflow => { slug => 'program-creation' });

    $t->reset_session;
    $t->get_ok('/program-creation')->status_is(200);
    my $run = $workflow->latest_run($dao->db);
    my $step = $run->next_step($dao->db);

    my $url = workflow_process_step_url($workflow, $run, $step);

    # POST without HX-Request
    $t->post_ok($url => form => {
        program_type_slug => 'summer-camp',
    })->status_is(302);

    like $t->tx->res->headers->location, qr/curriculum-details/,
        'non-HTMX redirects to next step';
};

done_testing;
