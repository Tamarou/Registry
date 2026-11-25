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
use Registry::WorkflowDivergence;

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
# And one that carries the public mark rather than roles.
Registry::DAO::Workflow->from_yaml( $dao, $home->child(qw( workflows tenant-storefront.yaml ))->slurp );

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

# Tenant $schema already holds a copy of $slug, as provisioning left it.
sub held_copy ( $schema, $slug ) {
    my $id = $db->query( 'SELECT id FROM registry.workflows WHERE slug = ?', $slug )->array->[0];
    my $q  = $db->dbh->quote_identifier($schema);
    $db->query( "INSERT INTO $q.outcome_definitions (id, name, schema)
                 SELECT id, name, schema FROM registry.outcome_definitions ON CONFLICT DO NOTHING" );
    $db->query( 'SELECT copy_workflow(dest_schema => ?, workflow_id => ?)', $schema, $id );
}

# Edits tenant $schema's copy of $slug away from the platform's.
sub diverge ( $schema, $slug ) {
    my $q = $db->dbh->quote_identifier($schema);
    $db->query( qq{UPDATE $q.workflow_steps s SET class = 'Registry::DAO::WorkflowStep'
                     FROM $q.workflows w WHERE w.id = s.workflow_id AND w.slug = ? AND s.slug = 'complete'}, $slug );
}

subtest 'an identical copy is kept as the one copy' => sub {
    my $tenant = bare_tenant('accept_same');
    held_copy( 'accept_same', 'session-creation' );
    my $result = Registry::DAO::Tenant->accept_platform_offer( $db, $tenant, grant() );
    is copies( 'accept_same', 'session-creation' ), 1, 'one copy, no duplicate';
    is_deeply definition( 'accept_same', 'session-creation' ), definition( 'registry', 'session-creation' ),
        "still the platform's definition";
    is $result->{workflows}{'session-creation'}, 'identical', 'reported as identical';
    is $result->{workflows}{'event-creation'}, 'copied', 'the missing one is copied';
};

subtest 'a diverged copy with no ruling is kept and reported' => sub {
    my $tenant = bare_tenant('accept_unruled');
    held_copy( 'accept_unruled', 'session-creation' );
    diverge( 'accept_unruled', 'session-creation' );
    my $before = definition( 'accept_unruled', 'session-creation' );
    my $result = Registry::DAO::Tenant->accept_platform_offer( $db, $tenant, grant(), {} );
    is_deeply definition( 'accept_unruled', 'session-creation' ), $before, 'its copy is left as it was';
    like $result->{workflows}{'session-creation'}, qr/^kept: diverged, no ruling\n.*step `complete`: class/s,
        'the accept records why, naming the difference';
    ok( Registry::DAO::Entitlement->may_run( $db, $tenant->id, 'session-creation' ), 'it still holds the run right' );
};

subtest 'a replace ruling gets the platform definition' => sub {
    my $tenant = bare_tenant('accept_replace');
    held_copy( 'accept_replace', 'session-creation' );
    diverge( 'accept_replace', 'session-creation' );
    my $result = Registry::DAO::Tenant->accept_platform_offer( $db, $tenant, grant(),
        Registry::WorkflowDivergence::rulings("Ruling: replace accept_replace/session-creation\n") );
    is_deeply definition( 'accept_replace', 'session-creation' ), definition( 'registry', 'session-creation' ),
        "the platform's definition replaced the copy";
    is copies( 'accept_replace', 'session-creation' ), 1, 'one copy';
    is $db->query('SELECT count(*) FROM accept_replace.templates')->array->[0], 6,
        "the old copy's templates went with it";
    is $result->{workflows}{'session-creation'}, 'replaced', 'reported as replaced';
};

subtest 'signup accepting the offer copies each workflow once' => sub {
    my $tenant = Registry::DAO::Tenant->provision( $db,
        { name => 'Signup Studio', slug => 'accept_signup', platform_entitlement => grant() } );
    is copies( 'accept_signup', $_ ), 1, "one copy of $_" for qw( session-creation event-creation );
    is_deeply definition( 'accept_signup', 'session-creation' ), definition( 'registry', 'session-creation' ),
        "the platform's definition";
    is entitlements($tenant), 1, 'and one entitlement';
};

sub refusal_of ($code) { eval { $code->(); 1 } ? undef : $@ }

subtest 'accepting twice yields one copy and one entitlement' => sub {
    my $tenant = bare_tenant('accept_twice');
    Registry::DAO::Tenant->accept_platform_offer( $db, $tenant, grant() );
    my $again = refusal_of( sub { Registry::DAO::Tenant->accept_platform_offer( $db, $tenant, grant() ) } );
    isa_ok $again, 'Registry::DAO::Entitlement::Refused', 'the second accept';
    is copies( 'accept_twice', $_ ), 1, "one copy of $_" for qw( session-creation event-creation );
    is entitlements($tenant), 1, 'one entitlement';
};

subtest 'failed copy leaves no entitlement and no partial workflow' => sub {
    my $tenant = bare_tenant('accept_fails');
    # A template already named as one session-creation's copy inserts, so the
    # copy fails partway: after event-creation and session-creation's steps.
    $db->insert( 'accept_fails.templates',
        { name => 'session-creation/info', slug => 'stray-info', content => 'stray' } );
    ok refusal_of( sub { Registry::DAO::Tenant->accept_platform_offer( $db, $tenant, grant() ) } ),
        'the accept fails';
    is entitlements($tenant), 0, 'no entitlement';
    is $db->query('SELECT count(*) FROM accept_fails.workflows')->array->[0], 0, 'no workflow';
    is $db->query('SELECT count(*) FROM accept_fails.workflow_steps')->array->[0], 0, 'no steps';
    is_deeply $db->query('SELECT slug FROM accept_fails.templates')->arrays->flatten->to_array, ['stray-info'],
        'no copied template, and the stray one untouched';
};

subtest 'replace ruling applies only to its tenant and slug' => sub {
    my ( $a, $b ) = map { bare_tenant($_) } qw( ruled_a ruled_b );
    for my $schema (qw( ruled_a ruled_b )) {
        for my $slug (qw( session-creation event-creation )) { held_copy( $schema, $slug ); diverge( $schema, $slug ) }
    }
    my %before;
    for my $schema (qw( ruled_a ruled_b )) {
        $before{"$schema/$_"} = definition( $schema, $_ ) for qw( session-creation event-creation );
    }
    my $rulings = Registry::WorkflowDivergence::rulings("Ruling: replace ruled_a/session-creation\n");
    Registry::DAO::Tenant->accept_platform_offer( $db, $_, grant(), $rulings ) for $a, $b;

    is_deeply definition( 'ruled_a', 'session-creation' ), definition( 'registry', 'session-creation' ),
        "the ruled tenant's ruled slug is replaced";
    is_deeply definition( 'ruled_a', 'event-creation' ), $before{'ruled_a/event-creation'},
        'its other slug is not';
    is_deeply definition( 'ruled_b', $_ ), $before{"ruled_b/$_"}, "another tenant's $_ is not"
        for qw( session-creation event-creation );
};

subtest 'merge ruling does not overwrite' => sub {
    my $tenant = bare_tenant('accept_merge');
    held_copy( 'accept_merge', 'session-creation' );
    diverge( 'accept_merge', 'session-creation' );
    my $before = definition( 'accept_merge', 'session-creation' );
    my $result = Registry::DAO::Tenant->accept_platform_offer( $db, $tenant, grant(),
        Registry::WorkflowDivergence::rulings("Ruling: merge accept_merge/session-creation\n") );
    is_deeply definition( 'accept_merge', 'session-creation' ), $before, 'its copy is left as it was';
    like $result->{workflows}{'session-creation'}, qr/^kept: merge ruling, needs a hand merge\n/,
        'and the accept records that it needs a hand merge';
};

subtest 'copy target is the accepting tenant only' => sub {
    my ( $mine, $other ) = map { bare_tenant($_) } qw( target_mine target_other );
    my %named = ( holder_tenant_id => $other->id, slug => 'target_other', schema => 'target_other',
        tenant => 'target_other', dest_schema => 'target_other' );
    Registry::DAO::Tenant->accept_platform_offer( $db, $mine, { %{ grant() }, %named } );
    is copies( 'target_mine', 'session-creation' ), 1, 'the accepting tenant has the copy';
    is $db->query('SELECT count(*) FROM target_other.workflows')->array->[0], 0, 'the named tenant has none';
    is entitlements($mine), 1, 'the accepting tenant holds the entitlement';
    is entitlements($other), 0, 'the named tenant holds none';
};

subtest 'unpublished offer acceptance refused without copy' => sub {
    my $tenant = bare_tenant('accept_stale');
    my $offer  = Registry::DAO::Offer->create( $db, { name => 'Stale bundle' } );
    my $terms  = offer_terms( undef, resource_ids => [ run_resource('session-creation')->id ], price_cents => 0,
        payment_plans => [ { id => 'share', kind => 'percentage_of_sales', fraction => 0.01 } ] );
    my $old    = $offer->draft( $db, $terms )->publish($db);
    $offer->draft( $db, $terms )->publish($db);    # supersedes $old
    my $draft  = $offer->draft( $db, $terms );

    # A version the tenant `elsewhere` offers in its own schema: not the platform's.
    my $elsewhere = bare_tenant('accept_elsewhere');
    my $own       = $elsewhere->dao($dao)->db;
    my $foreign   = Registry::DAO::Offer->create( $own, { name => 'Foreign bundle' } )->draft( $own,
        { %$terms, resource_ids => [ Registry::DAO::Resource->create( $own,
            { name => 'run:session-creation', kind => 'unbounded' } )->id ] } )->publish($own);

    for my $case ( [ unpublished => $db, $draft ], [ superseded => $db, $old ],
                   [ 'not the platform\'s' => $db, $foreign ], [ 'not the platform\'s, on its own connection' => $own, $foreign ] ) {
        my ( $why, $conn, $version ) = @$case;
        isa_ok refusal_of( sub { Registry::DAO::Tenant->accept_platform_offer( $conn, $tenant, grant($version) ) } ),
            'Registry::DAO::Entitlement::Refused', "$why: refused";
    }
    is copies( 'accept_stale', 'session-creation' ), 0, 'no copy';
    is entitlements($tenant), 0, 'no entitlement in registry';
    is $own->query('SELECT count(*) FROM entitlements')->array->[0], 0, "none in the offering tenant's schema";
};

subtest 'platform definition untouched by accept' => sub {
    my $platform = sub {
        return {
            map( { $_ => definition( 'registry', $_ ) } qw( session-creation event-creation tenant-storefront ) ),
            templates => $db->query('SELECT id, name, slug, content FROM registry.templates ORDER BY id')->hashes->to_array,
            outcomes  => $db->query('SELECT id, name, schema::text FROM registry.outcome_definitions ORDER BY id')->hashes->to_array,
        };
    };
    my $before = $platform->();
    my $tenant = bare_tenant('accept_untouched');
    held_copy( 'accept_untouched', 'session-creation' );
    diverge( 'accept_untouched', 'session-creation' );
    Registry::DAO::Tenant->accept_platform_offer( $db, $tenant, grant(),
        Registry::WorkflowDivergence::rulings("Ruling: replace accept_untouched/session-creation\n") );
    is copies( 'accept_untouched', 'session-creation' ), 1, 'the tenant copy was replaced';
    is_deeply $platform->(), $before, "registry's workflows, templates and outcome definitions are unchanged";
};

subtest 'copied workflow keeps roles or public mark' => sub {
    my $tenant = bare_tenant('accept_roles');
    held_copy( 'accept_roles', 'session-creation' );
    diverge( 'accept_roles', 'session-creation' );
    Registry::DAO::Tenant->accept_platform_offer( $db, $tenant, grant( platform_bundle(qw( session-creation tenant-storefront )) ),
        Registry::WorkflowDivergence::rulings("Ruling: replace accept_roles/session-creation\n") );
    my $row = sub ( $schema, $slug ) {
        $db->query( "SELECT roles, public FROM $schema.workflows WHERE slug = ?", $slug )->hash;
    };
    is_deeply $row->( 'accept_roles', 'session-creation' ), { roles => [qw( admin staff )], public => 0 },
        'a replaced copy keeps its roles';
    is_deeply $row->( 'accept_roles', 'tenant-storefront' ), $row->( 'registry', 'tenant-storefront' ),
        'a new copy keeps the public mark';
    ok $row->( 'accept_roles', 'tenant-storefront' )->{public}, 'which is set';
};

subtest 'platform-only workflow never copied by accept' => sub {
    Registry::DAO::Workflow->from_yaml( $dao, $home->child(qw( workflows registry-storefront.yaml ))->slurp );
    my $tenant = bare_tenant('accept_platform_only');
    my $result = Registry::DAO::Tenant->accept_platform_offer( $db, $tenant,
        grant( platform_bundle(qw( session-creation registry-storefront )) ) );
    is copies( 'accept_platform_only', 'registry-storefront' ), 0, "the platform's storefront is not copied";
    ok !exists $result->{workflows}{'registry-storefront'}, 'nor reported as copied';
    is copies( 'accept_platform_only', 'session-creation' ), 1, 'the rest of the grant is';
};

subtest 'a copy differing only in roles is diverged' => sub {
    my $tenant = bare_tenant('accept_roles_differ');
    held_copy( 'accept_roles_differ', 'session-creation' );
    $db->query(q{UPDATE accept_roles_differ.workflows SET roles = '{admin}' WHERE slug = 'session-creation'});
    my $result = Registry::DAO::Tenant->accept_platform_offer( $db, $tenant, grant(), {} );
    like $result->{workflows}{'session-creation'}, qr/^kept: diverged, no ruling\n.*roles/s,
        'not kept as identical: reported as diverged, naming roles';

    my $public = bare_tenant('accept_public_differs');
    held_copy( 'accept_public_differs', 'session-creation' );
    $db->query(q{UPDATE accept_public_differs.workflows SET public = true, roles = NULL WHERE slug = 'session-creation'});
    like Registry::DAO::Tenant->accept_platform_offer( $db, $public, grant(), {} )->{workflows}{'session-creation'},
        qr/^kept: diverged, no ruling\n.*public/s, 'a public mark the platform lacks is a difference too';
};

subtest 'the recorded report rules nothing today' => sub {
    is_deeply Registry::WorkflowDivergence::rulings(), {}, '"Ruling: none needed" names no tenant or slug';
};

done_testing;
