#!/usr/bin/env perl
# ABOUTME: Tests for workflow layout template issues #126 and #133
# ABOUTME: Ensures no empty visible containers render and no duplicate headings appear

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;

use Registry;
use Registry::DAO::Workflow;

# Setup test database
my $t_db = Test::Registry::DB->new;
my $db   = $t_db->db;

$db->import_workflows(['workflows/tenant-signup.yml']);

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $db } );

$db->current_tenant('registry');

# Helper: start workflow run and return run_id and first step slug
sub start_workflow_run {
    $t->post_ok('/tenant-signup')->status_is(302);
    my $location = $t->tx->res->headers->location;
    my ( $run_id, $step_slug ) = $location =~ m{/tenant-signup/([\w-]+)/(\w+)};
    return ( $run_id, $step_slug );
}

# Issue #126: empty rounded-rectangle container must not render when no navigation content
subtest 'No empty workflow-navigation footer renders when no navigation content set' => sub {
    my ( $run_id, $step_slug ) = start_workflow_run();

    $t->get_ok("/tenant-signup/$run_id/$step_slug")
      ->status_is(200)
      ->element_exists_not(
        'footer[data-component="workflow-navigation"]:empty',
        'Empty workflow-navigation footer must not be present'
      );

    # Confirm the footer either does not exist at all or has visible content
    my $dom = $t->tx->res->dom;
    my $nav_footer = $dom->at('footer[data-component="workflow-navigation"]');
    if ( defined $nav_footer ) {
        my $inner = $nav_footer->content;
        $inner =~ s/\s+//g;    # strip all whitespace
        ok length($inner) > 0,
          'workflow-navigation footer, if present, has non-whitespace content';
    }
    else {
        pass 'workflow-navigation footer is absent (no navigation content)';
    }
};

# Issue #126: empty workflow-progress section must not render
subtest 'No empty workflow-progress section renders when no progress content set' => sub {
    my ( $run_id, $step_slug ) = start_workflow_run();

    $t->get_ok("/tenant-signup/$run_id/$step_slug")->status_is(200);

    my $dom = $t->tx->res->dom;
    my $progress_section = $dom->at('section[data-component="workflow-progress"]');
    if ( defined $progress_section ) {
        my $inner = $progress_section->content;
        $inner =~ s/\s+//g;
        ok length($inner) > 0,
          'workflow-progress section, if present, has non-whitespace content';
    }
    else {
        pass 'workflow-progress section is absent (no progress content)';
    }
};

# Issue #133: duplicate heading — layout renders title, step templates must not repeat it
subtest 'Profile step has title in layout header only, not duplicated in content' => sub {
    my ( $run_id, $step_slug ) = start_workflow_run();

    $t->get_ok("/tenant-signup/$run_id/$step_slug")->status_is(200);

    my $dom = $t->tx->res->dom;

    # The layout header renders the title
    my $header = $dom->at('header[data-component="workflow-header"]');
    ok defined $header, 'workflow-header element exists';

    if ( defined $header ) {
        my $header_h1 = $header->at('h1');
        ok defined $header_h1, 'Title h1 exists in workflow-header';
    }

    # The workflow-content section must NOT contain an h1 duplicating the title
    my $content_section = $dom->at('section[data-component="workflow-content"]');
    ok defined $content_section, 'workflow-content section exists';

    if ( defined $content_section ) {
        my @h1_in_content = $content_section->find('h1')->each;
        is scalar(@h1_in_content), 0,
          'No h1 headings inside workflow-content (title is in layout header)';
    }
};

done_testing();
