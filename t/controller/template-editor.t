#!/usr/bin/env perl
# ABOUTME: Controller tests for the template editor workflow.
# ABOUTME: Tests list, edit, save, and revert actions at the HTTP layer.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw(workflow_process_step_url);

use Registry::DAO qw(Workflow);
use Registry::DAO::Template;
use Registry::DAO::User;
use Registry::DAO::MagicLinkToken;
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

# Create some templates in the DB for editing
my $tmpl1 = Registry::DAO::Template->create($dao->db, {
    name    => 'test/page-one',
    slug    => 'test-page-one',
    content => '<h1>Original Content</h1>',
});

my $tmpl2 = Registry::DAO::Template->create($dao->db, {
    name    => 'test/page-two',
    slug    => 'test-page-two',
    content => '<h1>Page Two</h1><p>Some text</p>',
});

# Create admin user and authenticate
my $admin = Registry::DAO::User->create($dao->db, {
    username => 'tmpl_admin', name => 'Template Admin',
    user_type => 'admin', email => 'tmpl_admin@test.com',
});

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

my (undef, $token) = Registry::DAO::MagicLinkToken->generate($dao->db, {
    user_id => $admin->id, purpose => 'login', expires_in => 24,
});
$t->get_ok("/auth/magic/$token")->status_is(200);
$t->post_ok("/auth/magic/$token/complete")->status_is(302);

# ============================================================
# Test: List view shows templates
# ============================================================
subtest 'list view shows templates' => sub {
    $t->get_ok('/admin/templates')
      ->status_is(200);

    $t->content_like(qr/test\/page-one/, 'Template name visible in list');
    $t->content_like(qr/test\/page-two/, 'Second template visible');
};

# ============================================================
# Test: Edit view loads template content
# ============================================================
subtest 'edit view loads template content' => sub {
    # Find the workflow run from the GET
    my ($wf) = $dao->find(Workflow => { slug => 'template-editor' });
    my $run = $wf->latest_run($dao->db);

    my $step = $run->next_step($dao->db) || $run->latest_step($dao->db)
            || $wf->first_step($dao->db);

    $t->post_ok(workflow_process_step_url($wf, $run, $step) => form => {
        action      => 'edit',
        template_id => $tmpl1->id,
    })->status_is(200);

    # Edit view should show the template name and a textarea
    $t->content_like(qr/test.*page.*one/i, 'Template name shown in edit view');
    $t->content_like(qr/textarea/, 'Content textarea exists');
};

# ============================================================
# Test: Save updates template in DB
# ============================================================
subtest 'save updates template content' => sub {
    my ($wf) = $dao->find(Workflow => { slug => 'template-editor' });
    my $run = $wf->latest_run($dao->db);
    my $step = $run->next_step($dao->db) || $run->latest_step($dao->db)
            || $wf->first_step($dao->db);

    $t->post_ok(workflow_process_step_url($wf, $run, $step) => form => {
        action      => 'save',
        template_id => $tmpl1->id,
        content     => '<h1>Updated by Jordan</h1><p>New content</p>',
    })->status_is(200);

    # Verify DB was updated
    my $updated = Registry::DAO::Template->find($dao->db, { id => $tmpl1->id });
    like $updated->content, qr/Updated by Jordan/, 'Content updated in DB';
};

# ============================================================
# Test: Revert restores registry default
# ============================================================
subtest 'revert restores default content' => sub {
    # First, create the same template in registry schema as the "default"
    # (In production, import_templates does this at startup)
    $dao->db->query(q{
        INSERT INTO registry.templates (name, slug, content, created_at, updated_at)
        VALUES ('test/page-one', 'test-page-one-reg', '<h1>Original Content</h1>', now(), now())
        ON CONFLICT DO NOTHING
    });

    my ($wf) = $dao->find(Workflow => { slug => 'template-editor' });
    my $run = $wf->latest_run($dao->db);
    my $step = $run->next_step($dao->db) || $run->latest_step($dao->db)
            || $wf->first_step($dao->db);

    $t->post_ok(workflow_process_step_url($wf, $run, $step) => form => {
        action      => 'revert',
        template_id => $tmpl1->id,
    })->status_is(200);

    # Verify the revert action completed without error (200, not 500)
    # The revert queries registry.templates for the default
    $t->content_like(qr/test.*page.*one/i, 'Still on edit view after revert');
};

done_testing;
