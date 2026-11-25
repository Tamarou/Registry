#!/usr/bin/env perl
# ABOUTME: Accepting a platform offer that grants run rights copies those workflows into the tenant's schema.
# ABOUTME: An existing copy is kept when identical, replaced only by a replace ruling, and reported otherwise.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Mojo::Home;

use Test::Registry::DB;
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO::Tenant;
use Registry::DAO::Workflow;
use Registry::DAO::Template;
use Registry::DAO::Resource;
use Registry::DAO::Offer;
use Registry::DAO::Entitlement;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# Two platform workflows, with their templates, as `template import` and
# `workflow import` leave them in registry.
my $home = Mojo::Home->new;
for my $wf (qw( session-creation event-creation )) {
    Registry::DAO::Template->import_from_file( $dao, $_ )
        for $home->child( 'templates', $wf )->list->grep(qr/\.html\.ep$/)->each;
    Registry::DAO::Workflow->from_yaml( $dao, $home->child( 'workflows', "$wf.yml" )->slurp );
}

# A step of S carries an outcome definition, so the copy must bring it too.
my $outcome = $db->insert( 'registry.outcome_definitions',
    { name => 'Session intake', schema => { -json => { fields => [] } } }, { returning => 'id' } )->hash->{id};
$db->query( q{UPDATE registry.workflow_steps s SET outcome_definition_id = ?
                FROM registry.workflows w WHERE w.id = s.workflow_id AND w.slug = 'session-creation'
                 AND s.slug = 'info'}, $outcome );

sub run_resource ($slug) {
    return Registry::DAO::Resource->find( $db, { name => "run:$slug" } )
        // Registry::DAO::Resource->create( $db, { name => "run:$slug", kind => 'unbounded' } );
}

# The platform's offer of both workflows' run rights, published in registry.
my $made = 0;
sub platform_bundle (@slugs) {
    return Registry::DAO::Offer->create( $db, { name => 'Workflow bundle ' . ++$made } )->draft( $db,
        offer_terms( undef, resource_ids => [ map { run_resource($_)->id } @slugs ], price_cents => 0,
            payment_plans => [ { id => 'share', kind => 'percentage_of_sales', fraction => 0.01 } ] ) )
        ->publish($db);
}
my $bundle = platform_bundle(qw( session-creation event-creation ));
sub grant ( $version = $bundle ) { { offer_version_id => $version->id, payment_plan_id => 'share' } }

# A tenant with an empty schema: no workflow copies at all.
sub bare_tenant ($slug) {
    my $tenant = Registry::DAO::Tenant->create( $db, { name => "Studio $slug", slug => $slug } );
    $db->query( 'SELECT clone_schema(dest_schema => ?)', $slug );
    $db->query('SET search_path = registry, public');
    return $tenant;
}

# Workflow $slug as schema $schema holds it: the row, and its steps in slug
# order with class, template name and content, and outcome definition.
sub definition ( $schema, $slug ) {
    my $q  = $db->dbh->quote_identifier($schema);
    my $wf = $db->query( "SELECT id, name, slug, description, first_step, roles, public
                            FROM $q.workflows WHERE slug = ?", $slug )->hash or return undef;
    my $steps = $db->query( qq{
        SELECT s.slug, s.class, s.description, d.slug AS depends_on, t.name AS template, t.content,
               s.outcome_definition_id
          FROM $q.workflow_steps s
          LEFT JOIN $q.workflow_steps d ON d.id = s.depends_on
          LEFT JOIN $q.templates t ON t.id = s.template_id
         WHERE s.workflow_id = ? ORDER BY s.slug }, delete $wf->{id} )->hashes->to_array;
    return { %$wf, steps => $steps };
}

sub copies ( $schema, $slug ) {
    my $q = $db->dbh->quote_identifier($schema);
    return $db->query( "SELECT count(*) FROM $q.workflows WHERE slug = ?", $slug )->array->[0];
}

sub entitlements ($tenant) {
    return $db->query( 'SELECT count(*) FROM registry.entitlements WHERE holder_tenant_id = ?', $tenant->id )
        ->array->[0];
}

subtest 'a tenant without a copy gains it by accepting' => sub {
    my $tenant = bare_tenant('accept_fresh');
    is copies( 'accept_fresh', 'session-creation' ), 0, 'no copy before';

    my $result = Registry::DAO::Tenant->accept_platform_offer( $db, $tenant, grant() );

    is_deeply definition( 'accept_fresh', 'session-creation' ), definition( 'registry', 'session-creation' ),
        "the tenant's copy has the platform's steps, classes, templates and outcome definition";
    is_deeply definition( 'accept_fresh', 'event-creation' ), definition( 'registry', 'event-creation' ),
        'and so does every workflow the offer grants';
    is $db->query( 'SELECT schema->>? FROM accept_fresh.outcome_definitions WHERE id = ?', 'fields', $outcome )
        ->array->[0], '[]', 'the outcome definition is in its schema';
    ok( Registry::DAO::Entitlement->may_run( $db, $tenant->id, $_ ), "it holds the run right for $_" )
        for qw( session-creation event-creation );
    is $result->{workflows}{'session-creation'}, 'copied', 'the accept reports the copy';
    is scalar( grep { defined $_->{template} } definition( 'accept_fresh', 'session-creation' )->{steps}->@* ), 3,
        'every step brought its template';
};

subtest 'signup accepting the offer copies each workflow once' => sub {
    my $tenant = Registry::DAO::Tenant->provision( $db,
        { name => 'Signup Studio', slug => 'accept_signup', platform_entitlement => grant() } );
    is copies( 'accept_signup', $_ ), 1, "one copy of $_" for qw( session-creation event-creation );
    is_deeply definition( 'accept_signup', 'session-creation' ), definition( 'registry', 'session-creation' ),
        "the platform's definition";
    is entitlements($tenant), 1, 'and one entitlement';
};

done_testing;
