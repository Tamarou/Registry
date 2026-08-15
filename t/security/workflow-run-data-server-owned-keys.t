#!/usr/bin/env perl
# ABOUTME: Proves a client cannot write the server-owned workflow run-data keys __tenant_slug and user_id.
# ABOUTME: __tenant_slug alone selects the Stripe destination account, on_behalf_of, and the fee rate.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Mojo;
use Test::Registry::Helpers qw( authenticate_as );

use Registry::DAO qw(Workflow);
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::WorkflowRun;
use Registry::DAO::User;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# A real tenant schema so the tenant helper resolves <slug>.localhost instead of
# degrading to the platform.
Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Host Tenant',
    slug => 'hosttenant',
});
$dao->db->query('SELECT clone_schema(?)', 'hosttenant');

# Two passthrough steps: no outcome definition, so validate() is a no-op and
# whatever the client posts is merged into the run's data.
my $workflow = Registry::DAO::Workflow->create($dao->db, {
    name        => 'Run Data Test Workflow',
    slug        => 'run-data-test',
    description => 'Landing passthrough followed by a completion step',
});
my $landing = Registry::DAO::WorkflowStep->create($dao->db, {
    workflow_id => $workflow->id,
    slug        => 'landing',
    class       => 'Registry::DAO::WorkflowStep',
    description => 'Landing',
});
Registry::DAO::WorkflowStep->create($dao->db, {
    workflow_id => $workflow->id,
    slug        => 'complete',
    class       => 'Registry::DAO::WorkflowStep',
    description => 'Complete',
    depends_on  => $landing->id,
});
$workflow->update($dao->db, { first_step => 'landing' }, { id => $workflow->id });

my $session_user = Registry::DAO::User->create($dao->db, {
    name      => 'Logged In Parent',
    username  => 'loggedin',
    email     => 'loggedin@example.com',
    user_type => 'parent',
});
my $other_user = Registry::DAO::User->create($dao->db, {
    name      => 'Someone Else',
    username  => 'someoneelse',
    email     => 'someoneelse@example.com',
    user_type => 'parent',
});

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

# A run parked on the landing step, ready for a POST to the next one.
sub run_on_second_step {
    my $run = $workflow->new_run($dao->db);
    $run->process($dao->db, $landing, {});
    return $run;
}

sub data_for {
    my ($run_id) = @_;
    my ($fresh) = $dao->find(WorkflowRun => { id => $run_id });
    return $fresh->data;
}

subtest 'run creation ignores posted server-owned keys' => sub {
    $t->post_ok('/run-data-test' => form => {
        __tenant_slug => 'victim_tenant',
        user_id       => $other_user->id,
    })->status_is(302);

    my ($run_id) = $t->tx->res->headers->location =~ m{/run-data-test/([^/]+)/};
    my $data = data_for($run_id);

    ok !exists $data->{__tenant_slug},
        'posted __tenant_slug is not stored at run creation';
    ok !exists $data->{user_id},
        'posted user_id is not stored at run creation';
};

subtest 'a later step cannot plant them either' => sub {
    my $run = run_on_second_step();

    $t->post_ok("/run-data-test/${\ $run->id}/complete" => form => {
        __tenant_slug => 'victim_tenant',
        user_id       => $other_user->id,
    })->status_is(201);

    my $data = data_for($run->id);
    ok !exists $data->{__tenant_slug},
        'posted __tenant_slug is not stored on a subsequent step';
    ok !exists $data->{user_id},
        'posted user_id is not stored on a subsequent step';
};

subtest 'on a tenant host a later step gets the host tenant, not the posted one' => sub {
    my $run = run_on_second_step();

    $t->post_ok("/run-data-test/${\ $run->id}/complete"
        => { Host => 'hosttenant.localhost' }
        => form => { __tenant_slug => 'victim_tenant' }
    )->status_is(201);

    is data_for($run->id)->{__tenant_slug}, 'hosttenant',
        'run data carries the tenant the request actually arrived at';
};

# authenticate_as installs a permanent before_dispatch hook, so every request
# from here on is authenticated. Keep this subtest last.
subtest 'user_id comes from the session, not the request' => sub {
    authenticate_as($t, $session_user);
    my $run = run_on_second_step();

    $t->post_ok("/run-data-test/${\ $run->id}/complete" => form => {
        user_id => $other_user->id,
    })->status_is(201);

    is data_for($run->id)->{user_id}, $session_user->id,
        'the authenticated user wins over the posted user_id';
};

done_testing;
