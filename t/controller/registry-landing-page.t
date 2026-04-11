#!/usr/bin/env perl
# ABOUTME: Tests the registry tenant's customized landing page for Jordan's journey.
# ABOUTME: Verifies hero, problem cards, alignment section, and callcc CTA render correctly.

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
use Mojo::Home;
use Mojo::File;
use YAML::XS qw(Load);

my $template_file = 'templates/registry/tenant-storefront-program-listing.html.ep';
plan skip_all => "Template file $template_file not found" unless -f $template_file;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# Import all workflows
my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($dao, $file->slurp);
}

# Import all templates from filesystem (seeds the DB)
my @tmpl_files = Mojo::Home->new->child('templates')->list_tree->grep(qr/\.html\.ep$/)->each;
for my $file (@tmpl_files) {
    Registry::DAO::Template->import_from_file($dao, $file);
}

# Seed registry-like data: project with registration_workflow metadata
my $location = $dao->create(Location => {
    name => 'Online RegLP Test', slug => 'online-reglp-test',
    address_info => { type => 'virtual' }, metadata => {},
});
my $teacher = $dao->create(User => { username => 'system-reg-test', user_type => 'staff' });
my $project = $dao->create(Project => {
    name => 'Tiny Art Empire RegLP', slug => 'tiny-art-empire-reglp',
    notes => 'Platform for art educators',
    metadata => { registration_workflow => 'tenant-signup' },
});
my $session = $dao->create(Session => {
    name => 'Get Started', slug => 'get-started-reg-test',
    start_date => '2026-01-01', end_date => '2036-01-01',
    status => 'published', capacity => 999999, metadata => {},
});
my $event = $dao->create(Event => {
    time => '2026-01-01 00:00:00', duration => 0,
    location_id => $location->id, project_id => $project->id,
    teacher_id => $teacher->id, capacity => 999999, metadata => {},
});
$session->add_events($dao->db, $event->id);

# Load the registry landing page template into the DB
my $template_content = Mojo::File->new($template_file)->slurp;
$dao->db->update('templates',
    { content => $template_content },
    { name => 'tenant-storefront/program-listing' },
);

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

# ============================================================
# Test 1: Landing page renders with vaporwave design system
# ============================================================
subtest 'landing page renders with vaporwave design system' => sub {
    $t->get_ok('/')
      ->status_is(200);

    $t->element_exists('.landing-page', 'Landing page container present')
      ->element_exists('.landing-hero', 'Hero section present')
      ->element_exists('.landing-cta-button', 'CTA button present');

    # No Tailwind classes
    $t->content_unlike(qr/class="[^"]*bg-white/, 'No Tailwind classes');

    # No broken template escaping
    $t->content_unlike(qr/%%/, 'No literal %% in rendered output');
};

# ============================================================
# Test 2: Hero section has headline and subtitle
# ============================================================
subtest 'hero section has headline and subtitle' => sub {
    $t->get_ok('/')
      ->status_is(200);

    $t->element_exists('.landing-hero h1', 'Hero headline exists')
      ->element_exists('.landing-hero-subtitle', 'Hero subtitle exists');

    $t->text_like('.landing-hero h1', qr/Your art deserves a real business/,
        'Hero headline has correct copy');

    # CTA links to tenant-signup
    my $dom = $t->tx->res->dom;
    my $cta = $dom->at('form[action*="callcc"]');
    ok $cta, 'callcc form found';
    if ($cta) {
        like $cta->attr('action'), qr{/callcc/tenant-signup},
            'CTA targets tenant-signup workflow';
    }
};

# ============================================================
# Test 3: Problem cards section exists with 6 cards
# ============================================================
subtest 'problem cards section exists with 6 cards' => sub {
    $t->get_ok('/')
      ->status_is(200);

    $t->element_exists('.landing-features', 'Features section present')
      ->element_exists('.landing-feature-card', 'At least one feature card present');

    my $dom = $t->tx->res->dom;
    my $cards = $dom->find('.landing-feature-card');
    is $cards->size, 6, 'Six problem cards rendered';
};

# ============================================================
# Test 4: Alignment section with pricing
# ============================================================
subtest 'alignment section with pricing' => sub {
    $t->get_ok('/')
      ->status_is(200);

    $t->content_like(qr/2\.5%/, 'Revenue share percentage visible')
      ->content_like(qr/Free to Start/i, 'Free to start messaging visible');
};

# ============================================================
# Test 5: CTA button says Get Started
# ============================================================
subtest 'CTA button text' => sub {
    $t->get_ok('/')
      ->status_is(200);

    $t->text_like('.landing-cta-button', qr/Get Started/i, 'CTA says Get Started');
};

# ============================================================
# Test 6: No raw session data exposed
# ============================================================
subtest 'no raw session data on landing page' => sub {
    $t->get_ok('/')
      ->status_is(200);

    $t->content_unlike(qr/999999 spots left/, 'No raw capacity shown')
      ->content_unlike(qr/2036-01-01/, 'No evergreen end date shown');
};

done_testing;
