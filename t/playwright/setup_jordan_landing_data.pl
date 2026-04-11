#!/usr/bin/env perl
# ABOUTME: Seeds test data for Jordan's landing page browser tests.
# ABOUTME: Creates registry-like storefront data and loads the custom landing page template.

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Registry::DAO qw(Workflow);
use Registry::DAO::Template;
use Mojo::Home;
use Mojo::File;
use Mojo::JSON qw(encode_json);
use YAML::XS qw(Load);

die "DB_URL not set" unless $ENV{DB_URL};

my $dao = Registry::DAO->new(url => $ENV{DB_URL});

my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($dao, $file->slurp);
}

my @tmpl_files = Mojo::Home->new->child('templates')->list_tree->grep(qr/\.html\.ep$/)->each;
for my $file (@tmpl_files) {
    Registry::DAO::Template->import_from_file($dao, $file);
}

my $content = Mojo::File->new('templates/registry/tenant-storefront-program-listing.html.ep')->slurp;
$dao->db->update('templates',
    { content => $content },
    { name => 'tenant-storefront/program-listing' },
);

my $location = $dao->create(Location => {
    name         => 'Online Platform',
    slug         => 'online-jordan-test',
    address_info => { type => 'virtual' },
    metadata     => {},
});

my $teacher = $dao->create(User => {
    username  => 'system-jordan',
    user_type => 'staff',
});

my $project = $dao->create(Project => {
    name     => 'Tiny Art Empire Platform',
    slug     => 'tae-jordan-test',
    notes    => 'Platform for art educators',
    metadata => { registration_workflow => 'tenant-signup' },
});

my $session = $dao->create(Session => {
    name       => 'Get Started',
    slug       => 'get-started-jordan',
    start_date => '2026-01-01',
    end_date   => '2036-01-01',
    status     => 'published',
    capacity   => 999999,
    metadata   => {},
});

my $event = $dao->create(Event => {
    time        => '2026-01-01 00:00:00',
    duration    => 0,
    location_id => $location->id,
    project_id  => $project->id,
    teacher_id  => $teacher->id,
    capacity    => 999999,
    metadata    => {},
});

$session->add_events($dao->db, $event->id);

print encode_json({ status => 'seeded', project_id => $project->id });
