#!/usr/bin/env perl
# ABOUTME: Tests for the DBTemplates renderer plugin.
# ABOUTME: Verifies DB templates render as first-class templates with full layout support.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;

use Registry::DAO qw(Workflow);
use Registry::DAO::Template;
use Mojo::Cache;
use Mojo::Home;
use YAML::XS qw(Load);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# Import workflows and templates
my @wf_files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@wf_files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($dao, $file->slurp);
}
my @tmpl_files = Mojo::Home->new->child('templates')->list_tree->grep(qr/\.html\.ep$/)->each;
for my $file (@tmpl_files) {
    Registry::DAO::Template->import_from_file($dao, $file);
}

# Create test data so the storefront has something to render
my $location = $dao->create(Location => {
    name => 'Online DBR Test', slug => 'online-dbr-test',
    address_info => { type => 'virtual' }, metadata => {},
});
my $teacher = $dao->create(User => { username => 'system-dbr-test', user_type => 'staff' });
my $project = $dao->create(Project => {
    name => 'Test Program', slug => 'test-program-dbr',
    notes => 'A test program',
    metadata => { registration_workflow => 'tenant-signup' },
});
my $session = $dao->create(Session => {
    name => 'Test Session', slug => 'test-session-dbr',
    start_date => '2026-01-01', end_date => '2036-01-01',
    status => 'published', capacity => 999999, metadata => {},
});
my $event = $dao->create(Event => {
    time => '2026-01-01 00:00:00', duration => 0,
    location_id => $location->id, project_id => $project->id,
    teacher_id => $teacher->id, capacity => 999999, metadata => {},
});
$session->add_events($dao->db, $event->id);

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

# ============================================================
# Test 1: Filesystem template renders with layout (baseline)
# ============================================================
subtest 'filesystem template renders with full layout' => sub {
    $t->get_ok('/')
      ->status_is(200);

    # The default layout includes DOCTYPE, html, head with CSS
    $t->content_like(qr/<!DOCTYPE html>/i, 'Has DOCTYPE from layout')
      ->content_like(qr/theme\.css/, 'Has theme.css link from layout')
      ->content_like(qr/app\.css/, 'Has app.css link from layout');
};

# ============================================================
# Test 2: DB template override renders with layout
# ============================================================
subtest 'DB template override renders with full layout' => sub {
    # Customize the template in the DB and clear the renderer's compiled template cache
    # so the new content is picked up (the EP handler caches compiled templates)
    $t->app->renderer->cache(Mojo::Cache->new);

    $dao->db->update('templates',
        { content => q{
% layout 'default';
% title 'Custom DB Template';
% stash no_container => 1;
<div class="landing-page">
  <p class="db-template-marker">Rendered from DB</p>
</div>
        }},
        { name => 'tenant-storefront/program-listing' },
    );

    $t->get_ok('/')
      ->status_is(200);

    # DB content is rendered
    $t->element_exists('.db-template-marker', 'DB template content is rendered');
    $t->text_like('.db-template-marker', qr/Rendered from DB/, 'DB template text is correct');

    # Layout is applied (this is the key test)
    $t->content_like(qr/<!DOCTYPE html>/i, 'DB template has DOCTYPE from layout')
      ->content_like(qr/theme\.css/, 'DB template has theme.css from layout')
      ->content_like(qr/app\.css/, 'DB template has app.css from layout');
};

# ============================================================
# Test 3: DB template layout directives work (stash, title, etc.)
# ============================================================
subtest 'DB template layout directives work' => sub {
    $t->get_ok('/')
      ->status_is(200);

    # The title from the DB template should be in the HTML
    $t->content_like(qr/<title>Custom DB Template<\/title>/, 'Title from DB template is rendered');
};

# ============================================================
# Test 4: DB template has access to stash variables (programs, run)
# ============================================================
subtest 'DB template has access to stash variables' => sub {
    # Clear renderer cache and update template to use stash variables
    $t->app->renderer->cache(Mojo::Cache->new);
    $dao->db->update('templates',
        { content => q{
% layout 'default';
% title 'Stash Test';
% stash no_container => 1;
<div class="landing-page">
  <p class="program-count"><%= scalar @$programs %> programs</p>
  <p class="run-id"><%= $run->id %></p>
</div>
        }},
        { name => 'tenant-storefront/program-listing' },
    );

    $t->get_ok('/')
      ->status_is(200);

    $t->text_like('.program-count', qr/\d+ programs/, 'Programs stash variable accessible')
      ->element_exists('.run-id', 'Run stash variable accessible');
};

done_testing;
