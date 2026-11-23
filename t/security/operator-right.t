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
    # still its admin, but the row saying it holds the right is gone.
    $db->delete( 'registry.tenant_resources',
        { tenant_id => $platform->id, resource => 'operator' } );

    ok !Registry::DAO::Tenant->holds( $db, $platform->id, 'operator' ),
        'the platform tenant no longer holds the right';

    my $t = app_as($alex);
    $t->get_ok('/platform/jobs')->status_is( 403, 'the job queue is refused' );
    $t->get_ok('/platform/revenue')->status_is( 403, 'the revenue view is refused' );
    $t->get_ok('/platform/tenants')->status_is( 200,
        'the fleet is the platform admin screen, and is still served' );
    $t->get_ok('/platform/runbook')->status_is( 200, 'as is the runbook' );

    $db->insert( 'registry.tenant_resources',
        { tenant_id => $platform->id, resource => 'operator' } );
};

subtest 'an admin of another tenant is refused jobs and revenue' => sub {
    my $t = app_as($morgan);
    $t->get_ok('/platform/jobs')->status_is( 403, 'Morgan is refused the job queue' );
    $t->get_ok('/platform/revenue')->status_is( 403, 'and the revenue view' );
};

done_testing;
