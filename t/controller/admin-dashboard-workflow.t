#!/usr/bin/env perl
# ABOUTME: Tests for admin dashboard as a single-step stay workflow.
# ABOUTME: Verifies full page load, HTMX section filtering, and fragment rendering.

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;

use Registry::DAO qw(Workflow);
use Registry::DAO::WorkflowRun;
use Registry::DAO::User;
use Mojo::Home;
use YAML::XS qw(Load);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# Import workflows
my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($dao, $file->slurp);
}

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

# Create admin user and fake auth for all requests
my $admin = Registry::DAO::User->create($dao->db, {
    name      => 'Admin User',
    username  => 'dashboard_admin',
    email     => 'dashboard_admin@example.com',
    user_type => 'admin',
});

# Bypass auth by overriding require_auth and require_role helpers
$t->app->helper(require_auth => sub { 1 });
$t->app->helper(require_role => sub { 1 });

# ============================================================
# Workflow structure
# ============================================================

subtest 'admin-dashboard workflow is single-step' => sub {
    my ($workflow) = $dao->find(Workflow => { slug => 'admin-dashboard' });
    ok $workflow, 'admin-dashboard workflow exists';

    my $first = $workflow->first_step($dao->db);
    ok $first, 'has a first step';
    is $first->slug, 'dashboard-overview', 'first step is dashboard-overview';

    my $next = $first->next_step($dao->db);
    ok !$next, 'no second step (single-step workflow)';
};

# ============================================================
# Full page GET
# ============================================================

subtest 'GET /admin/dashboard renders full dashboard' => sub {
    $t->get_ok('/admin/dashboard')
      ->status_is(200)
      ->content_like(qr/<html/i, 'full page has layout')
      ->content_like(qr/Admin Dashboard/i, 'has dashboard title');
};

# ============================================================
# HTMX GET with section param returns fragment
# ============================================================

subtest 'HTMX GET with section param returns fragment' => sub {
    my ($workflow) = $dao->find(Workflow => { slug => 'admin-dashboard' });

    # GET to create a run
    $t->get_ok('/admin/dashboard')->status_is(200);
    my $run = $workflow->latest_run($dao->db);
    ok $run, 'run created';

    my $step = $run->latest_step($dao->db) || $workflow->first_step($dao->db);
    my $url = "/admin-dashboard/${\$run->id}/${\$step->slug}?section=program_overview&range=current";

    $t->get_ok($url => { 'HX-Request' => 'true' })
      ->status_is(200)
      ->content_unlike(qr/<html/i, 'HTMX section response is fragment');
};

subtest 'non-HTMX GET with section returns section content' => sub {
    my ($workflow) = $dao->find(Workflow => { slug => 'admin-dashboard' });
    my $run = $workflow->latest_run($dao->db);
    my $step = $run->latest_step($dao->db) || $workflow->first_step($dao->db);

    # Section requests render the sub-template (partial content).
    # Without HTMX, these are still useful for direct links / bookmarks.
    my $url = "/admin-dashboard/${\$run->id}/${\$step->slug}?section=program_overview";
    $t->get_ok($url)
      ->status_is(200);
};

# ============================================================
# HTMX GET for different sections
# ============================================================

subtest 'HTMX sections: todays_events, waitlist, notifications' => sub {
    my ($workflow) = $dao->find(Workflow => { slug => 'admin-dashboard' });
    my $run = $workflow->latest_run($dao->db);
    my $step = $run->latest_step($dao->db) || $workflow->first_step($dao->db);
    my $base = "/admin-dashboard/${\$run->id}/${\$step->slug}";

    for my $section (qw(todays_events waitlist_management recent_notifications)) {
        $t->get_ok("$base?section=$section" => { 'HX-Request' => 'true' })
          ->status_is(200);
        $t->content_unlike(qr/<html/i, "$section returns fragment");
    }
};

done_testing;
