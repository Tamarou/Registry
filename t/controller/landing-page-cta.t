#!/usr/bin/env perl
# ABOUTME: Tests for CTA functionality on the tenant storefront landing page.
# ABOUTME: Verifies callcc registration forms, program display, and accessibility.

use 5.42.0;
use warnings;
use utf8;

use Test::More;
use Test::Mojo;

use lib qw(lib t/lib);
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry;
use Registry::DAO qw(Workflow);
use Mojo::Home;
use YAML::XS qw(Load);

# Setup test database for app initialization
my $t_db = Test::Registry::DB->new;
my $db = $t_db->db;

# Import workflows
my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($db, $file->slurp);
}

# Create test app with database helper
my $t = Test::Mojo->new('Registry');
$t->app->helper(dao => sub { $db });

# Create test data so the storefront has programs to display
my $location = $db->create(Location => {
    name         => 'Test Studio',
    slug         => 'test-studio-cta',
    address_info => { street => '123 Main St' },
    metadata     => {},
});

my $program = $db->create(Project => {
    name              => 'Art Camp CTA Test',
    notes             => 'Test program for CTA tests',
    program_type_slug => undef,
    metadata          => {},
});

my $teacher = $db->create(User => { username => 'cta_teacher', user_type => 'staff' });

my $session = $db->create(Session => {
    name       => 'CTA Test Session',
    start_date => '2026-06-01',
    end_date   => '2026-06-05',
    status     => 'published',
    capacity   => 16,
    metadata   => {},
});

my $event = $db->create(Event => {
    time        => '2026-06-01 09:00:00',
    duration    => 420,
    location_id => $location->id,
    project_id  => $program->id,
    teacher_id  => $teacher->id,
    capacity    => 16,
    metadata    => {},
});
$session->add_events($db->db, $event->id);

# Test callcc registration CTA on landing page
subtest 'Registration CTA on landing page' => sub {
    $t->get_ok('/')
      ->status_is(200);

    # Program name is visible
    $t->content_like(qr/Art Camp CTA Test/, 'Program name visible on storefront');

    # Register button exists as callcc form
    my $dom = $t->tx->res->dom;
    my $callcc_form = $dom->at('form[action*="callcc"]');
    ok $callcc_form, 'callcc registration form exists';

    if ($callcc_form) {
        like $callcc_form->attr('action'), qr{/tenant-storefront/.+/callcc/},
            'CTA links to registration workflow via callcc';
    }
};

# Test CTA accessibility
subtest 'CTA accessibility' => sub {
    $t->get_ok('/')
      ->status_is(200);

    # Register buttons are accessible submit buttons
    $t->element_exists('button[type="submit"]', 'CTA is a proper submit button');
};

# Test CTA with custom registration workflow
subtest 'CTA respects registration_workflow metadata' => sub {
    use Mojo::JSON qw(encode_json);
    $db->db->update('projects',
        { metadata => encode_json({ registration_workflow => 'tenant-signup' }) },
        { id => $program->id },
    );

    $t->get_ok('/')
      ->status_is(200);

    my $dom = $t->tx->res->dom;
    my $callcc_form = $dom->at('form[action*="callcc"]');
    ok $callcc_form, 'callcc form found';

    if ($callcc_form) {
        like $callcc_form->attr('action'), qr{/callcc/tenant-signup},
            'CTA targets custom registration workflow from metadata';
    }
};

done_testing();
