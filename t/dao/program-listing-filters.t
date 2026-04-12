#!/usr/bin/env perl
# ABOUTME: Tests for ProgramListing filtering, grouping, and location data.
# ABOUTME: Validates query param filtering and program-type grouping for the storefront catalog.

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;

use Registry::DAO qw(Workflow);
use Registry::DAO::ProgramType;
use Registry::DAO::WorkflowSteps::ProgramListing;
use Mojo::Home;
use YAML::XS qw(Load);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# Import workflows
my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($dao, $file->slurp);
}

# --- Seed program types ---
$dao->db->insert('program_types', {
    name => 'After-School Program', slug => 'after-school',
    config => '{}',
}) unless $dao->find('Registry::DAO::ProgramType', { slug => 'after-school' });

$dao->db->insert('program_types', {
    name => 'Summer Camp', slug => 'summer-camp',
    config => '{}',
}) unless $dao->find('Registry::DAO::ProgramType', { slug => 'summer-camp' });

# --- Test Data: Two locations, two program types, multiple programs ---

my $loc_lincoln = $dao->create(Location => {
    name         => 'Lincoln Elementary',
    slug         => 'lincoln-elem-filter',
    address_info => { city => 'Orlando' },
    metadata     => {},
});

my $loc_sunset = $dao->create(Location => {
    name         => 'Sunset Middle School',
    slug         => 'sunset-middle-filter',
    address_info => { city => 'Orlando' },
    metadata     => {},
});

my $teacher = $dao->create(User => { username => 'filter-teacher', user_type => 'staff' });

# After-school program at Lincoln
my $prog_lincoln = $dao->create(Project => {
    name              => 'Art at Lincoln',
    slug              => 'art-lincoln-filter',
    notes             => 'After-school art program at Lincoln Elementary',
    program_type_slug => 'after-school',
    metadata          => {},
});

my $sess_lincoln = $dao->create(Session => {
    name       => 'Fall 2026',
    slug       => 'fall-2026-lincoln-filter',
    start_date => '2026-09-01',
    end_date   => '2026-12-15',
    status     => 'published',
    capacity   => 20,
    metadata   => {},
});

my $evt_lincoln = $dao->create(Event => {
    time        => '2026-09-01 15:00:00',
    duration    => 120,
    location_id => $loc_lincoln->id,
    project_id  => $prog_lincoln->id,
    teacher_id  => $teacher->id,
    capacity    => 20,
    metadata    => {},
});
$sess_lincoln->add_events($dao->db, $evt_lincoln->id);

# After-school program at Sunset
my $prog_sunset = $dao->create(Project => {
    name              => 'Pottery at Sunset',
    slug              => 'pottery-sunset-filter',
    notes             => 'After-school pottery at Sunset Middle School',
    program_type_slug => 'after-school',
    metadata          => {},
});

my $sess_sunset = $dao->create(Session => {
    name       => 'Fall 2026 Sunset',
    slug       => 'fall-2026-sunset-filter',
    start_date => '2026-09-01',
    end_date   => '2026-12-15',
    status     => 'published',
    capacity   => 15,
    metadata   => {},
});

my $evt_sunset = $dao->create(Event => {
    time        => '2026-09-01 15:00:00',
    duration    => 120,
    location_id => $loc_sunset->id,
    project_id  => $prog_sunset->id,
    teacher_id  => $teacher->id,
    capacity    => 15,
    metadata    => {},
});
$sess_sunset->add_events($dao->db, $evt_sunset->id);

# Summer camp (different program type, at Lincoln)
my $prog_camp = $dao->create(Project => {
    name              => 'Summer Art Camp',
    slug              => 'summer-camp-filter',
    notes             => 'Week-long summer art camp',
    program_type_slug => 'summer-camp',
    metadata          => {},
});

my $sess_camp = $dao->create(Session => {
    name       => 'Week 1 - June',
    slug       => 'week1-june-filter',
    start_date => '2026-06-01',
    end_date   => '2026-06-05',
    status     => 'published',
    capacity   => 16,
    metadata   => {},
});

my $evt_camp = $dao->create(Event => {
    time        => '2026-06-01 09:00:00',
    duration    => 420,
    location_id => $loc_lincoln->id,
    project_id  => $prog_camp->id,
    teacher_id  => $teacher->id,
    capacity    => 16,
    metadata    => {},
});
$sess_camp->add_events($dao->db, $evt_camp->id);

# Create a workflow run for the step
my $wf = $dao->find(Workflow => { slug => 'tenant-storefront' });
my $step = $wf->first_step($dao->db);

my $run = $dao->create(WorkflowRun => {
    workflow_id => $wf->id,
    data        => {},
});

# ============================================================
# Test 1: Unfiltered results include all programs
# ============================================================
subtest 'unfiltered results include all programs' => sub {
    my $data = $step->prepare_template_data($dao->db, $run, {});
    my @programs = @{$data->{programs}};

    ok @programs >= 3, 'At least 3 programs returned';

    my %names = map { $_->{project}->name => 1 } @programs;
    ok $names{'Art at Lincoln'}, 'Lincoln program present';
    ok $names{'Pottery at Sunset'}, 'Sunset program present';
    ok $names{'Summer Art Camp'}, 'Summer camp present';
};

# ============================================================
# Test 2: Location data included in results
# ============================================================
subtest 'location name and slug included in session data' => sub {
    my $data = $step->prepare_template_data($dao->db, $run, {});
    my @programs = @{$data->{programs}};

    my ($lincoln_prog) = grep { $_->{project}->name eq 'Art at Lincoln' } @programs;
    ok $lincoln_prog, 'Found Lincoln program';

    my $session = $lincoln_prog->{sessions}[0];
    ok $session->{location_name}, 'location_name present in session data';
    is $session->{location_name}, 'Lincoln Elementary', 'Correct location name';
    ok $session->{location_slug}, 'location_slug present in session data';
};

# ============================================================
# Test 3: Filter by location
# ============================================================
subtest 'filter by location' => sub {
    my $data = $step->prepare_template_data($dao->db, $run, {
        location => $loc_lincoln->id,
    });
    my @programs = @{$data->{programs}};

    my %names = map { $_->{project}->name => 1 } @programs;
    ok $names{'Art at Lincoln'}, 'Lincoln program present';
    ok $names{'Summer Art Camp'}, 'Summer camp at Lincoln present';
    ok !$names{'Pottery at Sunset'}, 'Sunset program filtered out';
};

# ============================================================
# Test 4: Filter by program type
# ============================================================
subtest 'filter by program type' => sub {
    my $data = $step->prepare_template_data($dao->db, $run, {
        program_type => 'after-school',
    });
    my @programs = @{$data->{programs}};

    my %names = map { $_->{project}->name => 1 } @programs;
    ok $names{'Art at Lincoln'}, 'Lincoln after-school present';
    ok $names{'Pottery at Sunset'}, 'Sunset after-school present';
    ok !$names{'Summer Art Camp'}, 'Summer camp filtered out';
};

# ============================================================
# Test 5: Programs grouped by type
# ============================================================
subtest 'programs grouped by type in result' => sub {
    my $data = $step->prepare_template_data($dao->db, $run, {});

    ok exists $data->{grouped_programs}, 'grouped_programs key exists';

    my $grouped = $data->{grouped_programs};
    ok $grouped->{'after-school'}, 'after-school group exists';
    ok $grouped->{'summer-camp'}, 'summer-camp group exists';

    my @afterschool = @{$grouped->{'after-school'}};
    is scalar @afterschool, 2, 'Two after-school programs';
};

# ============================================================
# Test 6: Filter options (available locations and types)
# ============================================================
subtest 'filter options provided for template' => sub {
    my $data = $step->prepare_template_data($dao->db, $run, {});

    ok exists $data->{filter_locations}, 'filter_locations provided';
    ok exists $data->{filter_program_types}, 'filter_program_types provided';

    my @locs = @{$data->{filter_locations}};
    ok @locs >= 2, 'At least 2 locations available';

    my @types = @{$data->{filter_program_types}};
    ok @types >= 2, 'At least 2 program types available';
};

done_testing;
