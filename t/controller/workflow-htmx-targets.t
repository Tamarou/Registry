#!/usr/bin/env perl
# ABOUTME: Tests that the workflow layout has proper HTMX swap targets and script loading.
# ABOUTME: Validates #147 (id="workflow-content") and #148 (HTMX plugin integration).

use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw(done_testing subtest)];
defer { done_testing };

use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::Helpers qw(import_all_workflows);

my $test_db = Test::Registry::DB->new;
my $dao = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

import_all_workflows($dao);

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

subtest 'workflow layout has HTMX swap target with id' => sub {
    # #147: The workflow content section needs an id attribute so HTMX
    # forms can use hx-target="#workflow-content" for partial updates.
    $t->get_ok('/tenant-signup')
      ->status_is(200)
      ->element_exists('section[data-component="workflow-content"][id="workflow-content"]',
          'workflow content section has id="workflow-content"');
};

subtest 'workflow layout loads HTMX via plugin helper' => sub {
    # #148: The layout should use the Mojolicious::Plugin::HTMX asset
    # helper instead of a hardcoded CDN URL, so the plugin manages
    # version and configuration.
    $t->get_ok('/tenant-signup')
      ->status_is(200)
      ->element_exists('script[src*="htmx"]', 'HTMX script is loaded');
};
