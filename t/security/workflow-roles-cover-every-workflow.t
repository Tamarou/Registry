#!/usr/bin/env perl
# ABOUTME: Every imported workflow is either guarded by a workflow_roles entry or deliberately marked public.
# ABOUTME: A workflow added with neither fails here, by file and slug, instead of being silently open to anyone.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Mojo::Home;
use YAML::XS qw(Load);

# The role gate is open by default: require_workflow_role lets a slug with no
# workflow_roles entry through (Registry.pm, "or return 1"). Until step 6 makes
# who-may-run-what data, the guard is this test: a workflow the importer would
# load must either name its roles in workflow_roles or say, in its own YAML,
# `public: true`.
my $test_db = Test::Registry::DB->new;
$ENV{DB_URL} = $test_db->uri;
my $app = Test::Registry::Mojo->new('Registry')->app;

my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml\z/)->each;
ok scalar @files, 'there are workflow files to check';

for my $file (@files) {
    my $data = Load( $file->slurp );
    next if $data->{draft};    # exactly what import_workflows skips
    my $slug = $data->{slug} // lc( $data->{name} =~ s/\s+/-/gr );
    my $name = $file->basename;
    ok defined $app->workflow_roles($slug) || ( $data->{public} // '' ) eq '1',
      "$name ($slug) has a workflow_roles entry or the public mark";
}

done_testing;
