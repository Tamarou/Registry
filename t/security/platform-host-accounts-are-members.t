#!/usr/bin/env perl
# ABOUTME: An account a workflow creates on the platform host is a platform member in its own role.
# ABOUTME: Authority in a tenant is the membership role, so an account without one could do nothing there.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::User;
use Registry::DAO::Tenant;
use Registry::DAO::WorkflowSteps::AccountCheck;
use Registry::DAO::WorkflowSteps::CreateUser;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;    # the registry schema: the platform tenant's own

sub workflow_with ( $db, $slug, $class ) {
    my $wf = Registry::DAO::Workflow->create( $db, { name => $slug, slug => $slug, description => $slug } );
    my $row = Registry::DAO::WorkflowStep->create( $db, {
        workflow_id => $wf->id, slug => 'step', class => $class, description => 'step' } );
    $wf->update( $db, { first_step => 'step' }, { id => $wf->id } );
    return ( $wf, $class->new( id => $row->id, workflow_id => $wf->id, slug => 'step',
                               description => 'step', class => $class ) );
}

subtest 'a parent who signs up on the platform host is a platform member as parent' => sub {
    my ( $wf, $step ) = workflow_with( $db, 'platform-account-check', 'Registry::DAO::WorkflowSteps::AccountCheck' );
    $wf->new_run($db);
    $step->process( $db, { action => 'create_account', username => 'platform_signup_parent',
                           email => 'platform-parent@example.com', name => 'Platform Parent' } );

    my $user = Registry::DAO::User->find( $db, { username => 'platform_signup_parent' } );
    ok $user, 'the account exists';
    is Registry::DAO::Tenant->role_in( $db, 'registry', $user->id ), 'parent', 'and is a parent of the platform';
};

subtest 'staff the platform creates through user-creation are platform staff' => sub {
    my ( $wf, $step ) = workflow_with( $db, 'platform-user-creation', 'Registry::DAO::WorkflowSteps::CreateUser' );
    my $run = $wf->new_run($db);
    $run->update_data( $db, { username => 'platform_new_staff', user_type => 'staff', __tenant_slug => 'registry' } );
    $step->process( $db, {}, $run );

    my $user = Registry::DAO::User->find( $db, { username => 'platform_new_staff' } );
    ok $user, 'the account exists';
    is Registry::DAO::Tenant->role_in( $db, 'registry', $user->id ), 'staff', 'and is staff of the platform';
};

subtest 'an account created in a studio schema stays that studio own and needs no membership' => sub {
    Test::Registry::Fixtures::create_tenant( $db, { name => 'Local Studio', slug => 'local_studio' } );
    my $studio_db = Registry::DAO->new( url => $test_db->uri, schema => 'local_studio' )->db;
    my ( $wf, $step ) = workflow_with( $studio_db, 'studio-account-check', 'Registry::DAO::WorkflowSteps::AccountCheck' );
    $wf->new_run($studio_db);
    my $result = $step->process( $studio_db, { action => 'create_account', username => 'studio_local_parent',
                                               email => 'studio-parent@example.com', name => 'Studio Parent' } );

    ok !$result->{errors}, 'signing up there still works' or diag explain $result;
    my $user = Registry::DAO::User->find( $studio_db, { username => 'studio_local_parent' } );
    is Registry::DAO::Tenant->role_in( $db, 'local_studio', $user->id ), 'parent', 'with the role the studio recorded';
    ok !$db->query( 'SELECT 1 FROM registry.tenant_users WHERE user_id = ?', $user->id )->rows,
        'and no registry membership, which it could not hold';
};

done_testing;
