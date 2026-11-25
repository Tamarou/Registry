#!/usr/bin/env perl
# ABOUTME: Pins the read-only report of how each tenant's workflow copies differ from registry's:
# ABOUTME: slug, step order, step class and template (name and exact content), as committable Markdown.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Tenant;
use Registry::DAO::Workflow;
use Registry::WorkflowDivergence;
use Mojo::Home;
use YAML::XS qw(Load);
use Registry;
use Registry::Command::template;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# Workflows and templates in registry the way production has them, so a
# provisioned tenant holds real copies of both.
for my $file ( Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each ) {
    next if Load( $file->slurp )->{draft};
    Registry::DAO::Workflow->from_yaml( $dao, $file->slurp );
}
{
    local $ENV{DB_URL} = $test_db->uri;
    my $out = '';
    local *STDOUT;
    open STDOUT, '>', \$out;
    Registry::Command::template->new( app => Registry->new )->load('registry');
}

my $owner = Test::Registry::Fixtures::create_user( $db,
    { username => 'div_owner', name => 'Div Owner', email => 'owner@div.test', user_type => 'admin' } );

my $n = 0;
sub provision () {
    my $slug = 'div_' . ++$n;
    Registry::DAO::Tenant->provision( $db, { name => "Div $n", slug => $slug, users => [$owner] } );
    return $slug;
}

# The report's section for $slug: the lines after its heading, up to the next.
sub section ( $report, $slug ) {
    my ($body) = $report =~ /^## \Q$slug\E\n(.*?)(?=^## |\z)/ms;
    return $body;
}

subtest 'an untouched tenant copy reports no differences' => sub {
    my $slug   = provision();
    my $report = Registry::WorkflowDivergence::report($db);
    is section( $report, $slug ), "\nNo differences.\n\n", 'the section says so'
      or diag $report;
};

done_testing;
