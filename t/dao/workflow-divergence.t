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

# Run $sql against tenant $slug's schema (search_path set, then reset).
sub in_tenant ( $slug, $sql, @bind ) {
    $db->query( 'SET search_path = ' . $db->dbh->quote_identifier($slug) . ', public' );
    $db->query( $sql, @bind );
    $db->query('SET search_path = registry, public');
}

# Make $step follow $parent in workflow $wf of tenant $slug.
sub set_parent ( $slug, $wf, $step, $parent ) {
    in_tenant( $slug, q{
        UPDATE workflow_steps s SET depends_on = p.id
          FROM workflow_steps p, workflows w
         WHERE w.slug = ? AND s.workflow_id = w.id AND p.workflow_id = w.id
           AND s.slug = ? AND p.slug = ?
    }, $wf, $step, $parent );
}

subtest 'a step class change is reported with both values' => sub {
    my $slug = provision();
    in_tenant( $slug, q{
        UPDATE workflow_steps s SET class = 'Registry::DAO::WorkflowStep'
          FROM workflows w
         WHERE w.slug = 'offer-publishing' AND s.workflow_id = w.id AND s.slug = 'publish'
    } );
    like section( Registry::WorkflowDivergence::report($db), $slug ),
      qr/^- `offer-publishing` step `publish`: class: registry `Registry::DAO::WorkflowSteps::PublishOfferVersion`; tenant `Registry::DAO::WorkflowStep`$/m;
};

subtest 'a removed step is reported in the step order' => sub {
    my $slug = provision();
    set_parent( $slug, 'offer-publishing', 'expiry-policy', 'change-policy' );
    in_tenant( $slug, q{
        DELETE FROM workflow_steps s USING workflows w
         WHERE w.slug = 'offer-publishing' AND s.workflow_id = w.id AND s.slug = 'use-policy'
    } );
    like section( Registry::WorkflowDivergence::report($db), $slug ),
      qr/^- `offer-publishing`: steps: registry `.*change-policy, use-policy, expiry-policy.*`; tenant `.*change-policy, expiry-policy.*`$/m;
};

subtest 'an added step is reported in the step order' => sub {
    my $slug = provision();
    in_tenant( $slug, q{
        INSERT INTO workflow_steps (slug, workflow_id, depends_on)
        SELECT 'extra', w.id, s.id FROM workflows w JOIN workflow_steps s ON s.workflow_id = w.id
         WHERE w.slug = 'offer-publishing' AND s.slug = 'complete'
    } );
    like section( Registry::WorkflowDivergence::report($db), $slug ),
      qr/^- `offer-publishing`: steps: registry `.*publish, complete`; tenant `.*publish, complete, extra`$/m;
};

subtest 'a reordered step is reported in the step order' => sub {
    my $slug = provision();
    set_parent( $slug, 'offer-publishing', 'offer-price',  'resource' );
    set_parent( $slug, 'offer-publishing', 'offer-basics', 'offer-price' );
    set_parent( $slug, 'offer-publishing', 'one-time-payment', 'offer-basics' );
    like section( Registry::WorkflowDivergence::report($db), $slug ),
      qr/^- `offer-publishing`: steps: registry `resource, offer-basics, offer-price, one-time-payment, .*`; tenant `resource, offer-price, offer-basics, one-time-payment, .*`$/m;
};

# The tenant's template for one step that has one: [step, workflow, template name].
sub a_templated_step ($slug) {
    my $schema = $db->dbh->quote_identifier($slug);
    return $db->query( qq{
        SELECT s.slug, w.slug, t.name FROM $schema.workflow_steps s
          JOIN $schema.workflows w ON w.id = s.workflow_id
          JOIN $schema.templates t ON t.id = s.template_id
         WHERE w.slug = 'offer-publishing' AND s.slug = 'publish'
    } )->array;
}

subtest 'a template content change is reported' => sub {
    my $slug = provision();
    my ( $step, $wf, $name ) = a_templated_step($slug)->@*;
    ok $name, 'the step has a template to change';
    in_tenant( $slug, q{UPDATE templates SET content = content || '<p>ours</p>' WHERE name = ?}, $name );
    like section( Registry::WorkflowDivergence::report($db), $slug ),
      qr/^- `$wf` step `$step`: template content: registry sha256 `[0-9a-f]{12}` \(\d+ bytes\); tenant sha256 `[0-9a-f]{12}` \(\d+ bytes\)$/m;
};

subtest 'a template name change is reported' => sub {
    my $slug = provision();
    my ( $step, $wf, $name ) = a_templated_step($slug)->@*;
    in_tenant( $slug, q{UPDATE templates SET name = 'ours/publish' WHERE name = ?}, $name );
    like section( Registry::WorkflowDivergence::report($db), $slug ),
      qr/^- `$wf` step `$step`: template: registry `\Q$name\E`; tenant `ours\/publish`$/m;
};

subtest 'a tenant-only slug is reported' => sub {
    my $slug = provision();
    in_tenant( $slug, q{INSERT INTO workflows (slug, name) VALUES ('studio-own', 'Ours')} );
    like section( Registry::WorkflowDivergence::report($db), $slug ),
      qr/^- `studio-own`: only in the tenant$/m;
};

subtest 'a registry slug missing from the tenant is reported, the two provisioning skips are not' => sub {
    my $slug = provision();
    in_tenant( $slug, q{
        DELETE FROM workflow_steps s USING workflows w
         WHERE w.slug = 'offer-publishing' AND s.workflow_id = w.id
    } );
    in_tenant( $slug, q{DELETE FROM workflows WHERE slug = 'offer-publishing'} );
    my $section = section( Registry::WorkflowDivergence::report($db), $slug );
    like $section, qr/^- `offer-publishing`: missing from the tenant$/m;
    unlike $section, qr/tenant-signup|registry-storefront/, 'expected absences are not reported';
};

subtest 'the workflow divergence command prints the report and writes nothing' => sub {
    require Registry::Command::workflow;
    my @schemas = ( 'registry', map { $_->[0] } $db->query(
        q{SELECT slug FROM registry.tenants WHERE slug <> 'registry' ORDER BY slug})->arrays->each );
    my $counts = sub {
        [ map { my $s = $db->dbh->quote_identifier($_);
                $db->query("SELECT (SELECT count(*) FROM $s.workflows), (SELECT count(*) FROM $s.workflow_steps),
                                   (SELECT count(*) FROM $s.templates), (SELECT max(updated_at) FROM $s.templates)")->array }
          @schemas ];
    };
    my $before = $counts->();

    local $ENV{DB_URL} = $test_db->uri;
    my $out = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$out;
        Registry::Command::workflow->new( app => Registry->new )->run( 'divergence', 'registry' );
    }
    is $out, Registry::WorkflowDivergence::report($db), 'it prints the Markdown report';
    like $out, qr/^# Tenant workflow divergence$/m, 'with its heading';
    is_deeply $counts->(), $before, 'no workflow, step or template row changed in any schema';
};

done_testing;
