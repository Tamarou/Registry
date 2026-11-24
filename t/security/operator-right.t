#!/usr/bin/env perl
# ABOUTME: The operator right is held by a tenant as seeded data and read through one seam.
# ABOUTME: The job queue and the cross-tenant revenue view are served only to admins of its holder.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( authenticate_as );
use Test::Registry::OperatorRight qw( revoke_operator restore_operator grant_in_schema );
use Registry::DAO::Tenant;
use Registry::DAO::User;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $platform = Registry::DAO::Tenant->platform($db);

my $studio = Test::Registry::Fixtures::create_tenant( $db, {
    name => 'Operator Right Studio', slug => 'operator_right_studio',
} );

subtest 'the platform tenant holds the operator right and other tenants do not' => sub {
    ok Registry::DAO::Tenant->holds( $db, $platform->id, 'operator' ),
        'the platform tenant holds operator, as the deploy migration seeded it';
    ok !Registry::DAO::Tenant->holds( $db, $studio->id, 'operator' ),
        'a provisioned tenant does not';
};

# Alex is the platform tenant's owner: an admin member of the tenant holding
# the right. Morgan is an admin member of a studio, which does not hold it.
my $alex = $platform->primary_user($db);

my $morgan = Registry::DAO::User->create( $db, {
    username => 'operator_morgan', name => 'Morgan', user_type => 'admin',
    email => 'morgan@operator-studio.test',
} );
$studio->add_user( $db, $morgan, 1 );

sub app_as ($user = undef) {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper( dao => sub { $dao } );
    authenticate_as( $t, $user ) if $user;
    return $t;
}

subtest 'an admin of the operator tenant is served jobs and revenue' => sub {
    my $t = app_as($alex);
    $t->get_ok('/platform/jobs')->status_is( 200, 'Alex is served the job queue' );
    $t->get_ok('/platform/revenue')->status_is( 200, 'and the revenue view' );
};

subtest 'without the operator right jobs and revenue are refused but tenants and runbook are served' => sub {
    # The test that no code decides "is this the operator" from the slug or the
    # all-zeros id: the platform tenant is still the platform tenant, and Alex
    # still its admin, but the entitlement saying it holds the right is gone.
    my $held = revoke_operator($db);

    ok !Registry::DAO::Tenant->holds( $db, $platform->id, 'operator' ),
        'the platform tenant no longer holds the right';

    my $t = app_as($alex);
    $t->get_ok('/platform/jobs')->status_is( 403, 'the job queue is refused' );
    $t->get_ok('/platform/revenue')->status_is( 403, 'the revenue view is refused' );
    $t->get_ok('/platform/tenants')->status_is( 200,
        'the fleet is the platform admin screen, and is still served' );
    $t->get_ok('/platform/runbook')->status_is( 200, 'as is the runbook' );

    restore_operator( $db, $held );
};

subtest 'an admin of another tenant is refused jobs and revenue' => sub {
    my $t = app_as($morgan);
    $t->get_ok('/platform/jobs')->status_is( 403, 'Morgan is refused the job queue' );
    $t->get_ok('/platform/revenue')->status_is( 403, 'and the revenue view' );
};

subtest 'staff and parent members of the platform tenant are refused the operator routes' => sub {
    # Ruling 4: the membership's role is what counts. Both are admins by the
    # global user_type, which must not be read.
    for my $role (qw( staff parent )) {
        my $member = Registry::DAO::User->create( $db, {
            username => "operator_platform_$role", name => "Platform \u$role",
            user_type => 'admin', email => "$role\@operator-platform.test",
        } );
        $platform->add_user( $db, $member, 0, $role );

        my $t = app_as($member);
        $t->get_ok('/platform/jobs')->status_is( 403,
            "a $role member is refused the job queue" );
        $t->get_ok('/platform/revenue')->status_is( 403,
            "a $role member is refused the revenue view" );
    }
};

subtest 'an operator grant in a tenant own schema copy grants nothing' => sub {
    # clone_schema gave the studio its own copy of the entitlement tables. A
    # row there is a tenant writing its own grant, and must be ignored.
    grant_in_schema( $dao, 'operator_right_studio', $studio->id, 'operator' );

    ok !Registry::DAO::Tenant->holds( $db, $studio->id, 'operator' ),
        'the read seam answers false through the registry handle';
    my $studio_db = $dao->connect_schema('operator_right_studio')->db;
    ok !Registry::DAO::Tenant->holds( $studio_db, $studio->id, 'operator' ),
        'and through a handle searching the studio schema first';

    my $t = app_as($morgan);
    $t->get_ok('/platform/jobs')->status_is( 403, 'the studio admin is refused the job queue' );
    $t->get_ok('/platform/revenue')->status_is( 403, 'and the revenue view' );
};

subtest 'a differently named resource does not grant the operator right' => sub {
    grant_in_schema( $dao, 'registry', $studio->id, 'operators' );

    ok !Registry::DAO::Tenant->holds( $db, $studio->id, 'operator' ),
        'holding another resource is not holding operator';

    my $t = app_as($morgan);
    $t->get_ok('/platform/jobs')->status_is( 403, 'the studio admin is refused the job queue' );
    $t->get_ok('/platform/revenue')->status_is( 403, 'and the revenue view' );
};

subtest 'without the operator right a minion action that changes a job is refused' => sub {
    my $t = app_as($alex);
    my $minion = $t->app->minion;
    my $id = $minion->enqueue( 'operator_right_probe', [], { queue => 'operator_right_probe' } );

    # From the app's own origin, as the dashboard's form is, so the CSRF hook
    # lets each request through and the refusals below are the operator guard's.
    my $own = { Origin => $t->ua->server->url->path('')->to_string =~ s{/\z}{}r };

    my $held = revoke_operator($db);

    $t->patch_ok( '/platform/jobs/jobs', $own, form => { id => $id, do => 'remove' } )
      ->status_is( 403, 'removing a job is refused' );
    ok $minion->job($id), 'and the job is still there';
    $t->patch_ok( '/platform/jobs/jobs', $own, form => { id => $id, do => 'retry' } )
      ->status_is( 403, 'retrying a job is refused' );
    is $minion->job($id)->info->{retries}, 0, 'and it was not retried';

    restore_operator( $db, $held );

    # The control: the same request is one the dashboard accepts once the right
    # is back, so the refusal above was the guard and not the request's shape.
    $t->patch_ok( '/platform/jobs/jobs', $own, form => { id => $id, do => 'remove' } )
      ->status_is( 302, 'with the right the same request is handled' );
    ok !$minion->job($id), 'and removes the job';
};

subtest 'an unauthenticated request is served neither operator route' => sub {
    my $t = app_as();
    $t->get_ok('/platform/jobs')->status_isnt( 200, 'the job queue is not served' )
      ->content_unlike( qr/minion/i, 'and is not the Minion dashboard' );
    $t->get_ok('/platform/revenue')->status_isnt( 200, 'the revenue view is not served' );
};

done_testing;
