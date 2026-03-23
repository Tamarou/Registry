#!/usr/bin/env perl
# ABOUTME: Tests that the workflow layout includes HTMX CSRF token configuration.
# ABOUTME: Verifies htmx:configRequest event listener and X-CSRF-Token header injection.

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;

use Registry;

# Setup test database
my $t_db = Test::Registry::DB->new;
my $db = $t_db->db;

# Import tenant-signup workflow
$db->import_workflows(['workflows/tenant-signup.yml']);

# Create test app
my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $db });

# Verify the workflow layout includes HTMX CSRF configuration
$t->get_ok('/tenant-signup')
  ->status_is(200)
  ->content_like(qr/htmx:configRequest/, 'Layout includes HTMX config request event')
  ->content_like(qr/X-CSRF-Token/, 'Layout configures CSRF header for HTMX');

done_testing;
