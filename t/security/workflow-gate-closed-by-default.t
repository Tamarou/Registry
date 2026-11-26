#!/usr/bin/env perl
# ABOUTME: The workflow gate reads who may run a workflow from the current tenant's own row and
# ABOUTME: refuses (403) a slug with no roles and no public mark, at every entry, creating no run.
use 5.42.0;
use warnings;
use utf8;
use experimental 'signatures';

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::SoloVersion qw(accept_solo);
use Test::Registry::DB;
use Test::Registry::Helpers qw(authenticate_as import_all_workflows);
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Workflow;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;

# Workflows into registry first: provision copies them into each tenant.
import_all_workflows($dao);

for my $slug (qw( gate_here gate_there )) {
    # Accepting Solo, as signup does, gives it the run rights: the role gate is what these subtests probe.
    accept_solo( $db, Registry::DAO::Tenant->provision( $db, { name => "Gate \u$slug", slug => $slug, users => [] } ) );
}
my $here      = Registry::DAO::Tenant->find( $db, { slug => 'gate_here' } );
my $HOST      = { Host => 'gate_here.localhost' };
my $here_dao  = $dao->connect_schema('gate_here');
my $there_dao = $dao->connect_schema('gate_there');

# A workflow in this tenant's schema with neither roles nor the public mark.
sub workflow_yaml ( $slug, $head = '' ) {
    return "name: $slug\nslug: $slug\ndescription: fixture\n$head"
      . "steps:\n  - slug: first\n    description: x\n  - slug: second\n    description: y\n";
}
Registry::DAO::Workflow->from_yaml( $here_dao, workflow_yaml('unguarded-flow') );

sub member ( $username, $role ) {
    my $user = Registry::DAO::User->create( $db, {
        username => $username, name => "\u$username", user_type => 'staff',
        email    => "$username\@workflow-gate.test",
    } );
    $here->add_user( $db, $user, 0, $role );
    $db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)', 'gate_here', $user->id );
    return $user;
}

sub app_as ($user = undef) {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->ua->max_redirects(0);
    authenticate_as( $t, $user ) if $user;
    return $t;
}

my $admin  = member( 'gate_admin',  'admin' );
my $parent = member( 'gate_parent', 'parent' );

subtest 'a workflow with no role entry and no public mark is refused for an anonymous visitor' => sub {
    my $t = app_as();
    $t->get_ok( '/unguarded-flow' => $HOST )->status_is(403);
    $t->post_ok( '/unguarded-flow' => $HOST => form => {} )->status_is(403);
};

subtest 'a workflow with no role entry and no public mark is refused for a parent' => sub {
    my $t = app_as($parent);
    $t->get_ok( '/unguarded-flow' => $HOST )->status_is(403);
    $t->post_ok( '/unguarded-flow' => $HOST => form => {} )->status_is(403);
};

subtest 'a public-marked workflow is reachable anonymously' => sub {
    app_as()->get_ok( '/tenant-storefront' => $HOST )->status_is(200);
};

subtest 'a roles workflow admits admin and refuses parent' => sub {
    app_as($admin)->get_ok( '/program-creation' => $HOST )->status_is(200);
    app_as($parent)->get_ok( '/program-creation' => $HOST )->status_is(403);
};

# The tenant's copy, not registry's row and not the YAML, says who may run it.
subtest "a tenant whose copy's roles differ from registry's is gated by its own copy" => sub {
    $here_dao->db->update( 'workflows', { roles => ['parent'] }, { slug => 'program-creation' } );
    app_as($parent)->get_ok( '/program-creation' => $HOST )->status_is(200);
    app_as($admin)->get_ok( '/program-creation' => $HOST )->status_is(403);
    $here_dao->db->update( 'workflows', { roles => [qw(admin staff)] }, { slug => 'program-creation' } );
};

sub runs_of ($slug) {
    $here_dao->db->query( q{
        SELECT count(*) FROM workflow_runs r JOIN workflows w ON w.id = r.workflow_id WHERE w.slug = ?
    }, $slug )->array->[0];
}

subtest 'slug missing from tenant schema refused despite platform row' => sub {
    ok $dao->db->query( q{SELECT public FROM registry.workflows WHERE slug = 'tenant-signup'} )->hash->{public},
      'registry has a public-marked tenant-signup';
    ok !$here_dao->find( 'Registry::DAO::Workflow', { slug => 'tenant-signup' } ), 'this tenant has no row for it';
    my $t = app_as();
    $t->get_ok( '/tenant-signup' => $HOST )->status_is(403);
    $t->post_ok( '/tenant-signup' => $HOST => form => {} )->status_is(403);
};

subtest 'other tenant public mark does not open this tenant' => sub {
    Registry::DAO::Workflow->from_yaml( $there_dao, workflow_yaml( 'elsewhere-flow', "public: true\n" ) );
    Registry::DAO::Workflow->from_yaml( $here_dao,  workflow_yaml('elsewhere-flow') );
    ok $there_dao->find( 'Registry::DAO::Workflow', { slug => 'elsewhere-flow' } )->public,
      "the other tenant's copy is public";
    my $t = app_as();
    $t->get_ok( '/elsewhere-flow' => $HOST )->status_is(403);
    $t->post_ok( '/elsewhere-flow' => $HOST => form => {} )->status_is(403);
};

subtest 'empty roles refused for admin too' => sub {
    Registry::DAO::Workflow->from_yaml( $here_dao, workflow_yaml( 'empty-roles-flow', "roles: [admin]\n" ) );
    $here_dao->db->update( 'workflows', { roles => [] }, { slug => 'empty-roles-flow' } );
    for my $who ( [ admin => $admin ], [ anonymous => undef ] ) {
        my $t = app_as( $who->[1] );
        $t->get_ok( '/empty-roles-flow' => $HOST )->status_is( 403, "$who->[0] refused" );
        $t->post_ok( '/empty-roles-flow' => $HOST => form => {} )->status_is( 403, "$who->[0] refused" );
    }
};

subtest 'continuing a run of an unguarded workflow refused' => sub {
    my $workflow = $here_dao->find( 'Registry::DAO::Workflow', { slug => 'unguarded-flow' } );
    my $run      = $workflow->new_run( $here_dao->db );
    my $before   = $here_dao->db->query( 'SELECT data::text, latest_step_id FROM workflow_runs WHERE id = ?', $run->id )->hash;
    for my $user ( undef, $parent, $admin ) {
        my $t = app_as($user);
        $t->post_ok( "/unguarded-flow/@{[ $run->id ]}/$_" => $HOST => form => { x => 1 } )->status_is(403)
          for qw(first second);
        $t->get_ok( "/unguarded-flow/@{[ $run->id ]}/second" => $HOST )->status_is(403);
    }
    is_deeply $here_dao->db->query( 'SELECT data::text, latest_step_id FROM workflow_runs WHERE id = ?', $run->id )->hash,
      $before, 'the run is unchanged';
};

subtest 'refused request creates no run' => sub {
    my $before     = runs_of('unguarded-flow');
    my $storefront = $here_dao->find( 'Registry::DAO::Workflow', { slug => 'tenant-storefront' } );
    my $from       = $storefront->new_run( $here_dao->db );
    for my $user ( undef, $parent, $admin ) {
        my $t = app_as($user);
        $t->get_ok( '/unguarded-flow' => $HOST )->status_is(403);
        $t->post_ok( '/unguarded-flow' => $HOST => form => {} )->status_is(403);
        $t->post_ok( "/tenant-storefront/@{[ $from->id ]}/callcc/unguarded-flow" => $HOST => form => {} )
          ->status_is( 403, 'a callcc into it is refused too' );
    }
    is runs_of('unguarded-flow'), $before, 'no run was created';
};

sub run_state ($id) {
    $here_dao->db->query( 'SELECT data::text, latest_step_id FROM workflow_runs WHERE id = ?', $id )->hash;
}

# The gate reads the URL's slug; the run must belong to that slug's workflow, or
# any run is reachable through a public slug. 404: the run's existence is not
# confirmed to someone who may not see it.
subtest 'a run cannot be continued through another workflow slug' => sub {
    for my $slug (qw( unguarded-flow program-creation )) {
        my $run    = $here_dao->find( 'Registry::DAO::Workflow', { slug => $slug } )->new_run( $here_dao->db );
        my $step   = $run->next_step( $here_dao->db )->slug;
        my $before = run_state( $run->id );
        my $url    = "/tenant-storefront/@{[ $run->id ]}/$step";
        for my $who ( [ anonymous => undef ], [ parent => $parent ] ) {
            my $t = app_as( $who->[1] );
            $t->get_ok( $url => $HOST )->status_is( 404, "$slug GET step, $who->[0]" );
            $t->post_ok( $url => $HOST => form => { x => 1 } )->status_is( 404, "$slug POST step, $who->[0]" );
            $t->get_ok( "$url?payment_intent=pi_gate_probe&redirect_status=succeeded" => $HOST )
              ->status_is( 404, "$slug Stripe return, $who->[0]" );
        }
        is_deeply run_state( $run->id ), $before, "the $slug run is unchanged";
    }
};

subtest 'callcc refuses a source run of another workflow' => sub {
    my $source = $here_dao->find( 'Registry::DAO::Workflow', { slug => 'unguarded-flow' } )->new_run( $here_dao->db );
    my $count  = sub {
        $here_dao->db->query( 'SELECT count(*) FROM workflow_runs WHERE continuation_id = ?', $source->id )->array->[0];
    };
    app_as()->post_ok( "/tenant-storefront/@{[ $source->id ]}/callcc/tenant-storefront" => $HOST => form => {} )
      ->status_is(404);
    is $count->(), 0, 'no run continues the foreign run';
};

# Routes that name their workflow in the route rather than the URL go through
# the same row-based check, so a tenant narrowing its row takes effect there.
subtest 'fixed-slug routes are gated by the tenant row' => sub {
    my $staff = member( 'gate_staff', 'staff' );
    for my $case (
        [ 'admin-dashboard',         get  => '/admin/dashboard' ],
        [ 'admin-drop-approval',     post => '/admin/dashboard/process_drop_request' ],
        [ 'admin-transfer-approval', post => '/admin/dashboard/process_transfer_request' ],
        [ 'template-editor',         get  => '/admin/templates' ],
        [ 'template-editor',         post => '/admin/templates' ],
      )
    {
        my ( $slug, $method, $path ) = @$case;
        $here_dao->db->update( 'workflows', { roles => ['admin'] }, { slug => $slug } );
        my $before = runs_of($slug);
        my $m      = "${method}_ok";
        app_as($staff)->$m( $path => $HOST => form => {} )
          ->status_is( 403, "$method $path refuses staff once narrowed" );
        is runs_of($slug), $before, "no $slug run created";
        $here_dao->db->update( 'workflows', { roles => [qw(admin staff)] }, { slug => $slug } );
    }

    $here_dao->db->update( 'workflows', { roles => ['admin'], public => 'false' }, { slug => 'tenant-storefront' } );
    my $before = runs_of('tenant-storefront');
    my $t      = app_as($parent);    # anonymous would be sent to log in instead
    $t->get_ok( '/' => $HOST )->status_is( 403, 'GET / follows the narrowed storefront row' );
    $t->post_ok( '/' => $HOST => form => {} )->status_is( 403, 'POST / follows the narrowed storefront row' );
    is runs_of('tenant-storefront'), $before, 'no storefront run created';
    $here_dao->db->update( 'workflows', { roles => undef, public => 'true' }, { slug => 'tenant-storefront' } );
    app_as()->get_ok( '/' => $HOST )->status_is( 200, 'the shipped storefront row still serves /' );
};

subtest 'malformed slug never bypasses guard' => sub {
    my $before = runs_of('program-creation');
    my $t      = app_as($parent);
    for my $path ( '/PROGRAM-CREATION', '/Program-Creation', '/program-creation%27', '/%27program-creation',
        '/x/../program-creation', '/%2E%2E/program-creation', '/program-creation/..' )
    {
        $t->get_ok( $path => $HOST );
        my $code = $t->tx->res->code;
        ok $code == 403 || $code == 404, "GET $path is refused or not found (got $code)";
        $t->post_ok( $path => $HOST => form => {} );
        $code = $t->tx->res->code;
        ok $code == 403 || $code == 404, "POST $path is refused or not found (got $code)";
    }
    is runs_of('program-creation'), $before, 'no program-creation run was created';
};

done_testing;
