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

subtest 'a bracketed variant cannot smuggle a structure into a server-owned key' => sub {
    my $run = run_on_second_step();

    # _apply_server_owned_data vets the FLAT param hash and touches only the
    # exact keys. expand_form_params runs afterwards, inside WorkflowStep, and
    # its bracket branch does `$ref->{$p} = {} unless ref $ref->{$p} eq 'HASH'`
    # -- destroying whatever scalar the server just put there and replacing it
    # with client-built structure. The scalar form of this attack is refused
    # above; the bracketed form went straight through.
    #
    # A structure here is not merely a wrong value. These keys are fed to
    # SQL::Abstract as WHERE values, where a hashref becomes an OPERATOR:
    # family_id => { '!=' => ... } renders `family_id != ?` and matches every
    # other family in the tenant.
    $t->post_ok("/run-data-test/${\ $run->id}/complete" => form => {
        'user_id[!=]'       => $other_user->id,
        '__tenant_slug[!=]' => 'victim_tenant',
    })->status_is(201);

    my $data = data_for($run->id);
    ok !ref $data->{user_id},
        'user_id is not a client-built structure';
    ok !ref $data->{__tenant_slug},
        '__tenant_slug is not a client-built structure';
};

subtest 'selected_pricing_plan cannot be planted by a client' => sub {
    my $run = run_on_second_step();

    # Same shape as the user_id bracket bypass above, on a different key. Only
    # the pricing step may write this: it rebuilds the blob from the plan row it
    # just validated, which is where the coming-soon refusal lives. A client-
    # authored blob skips that refusal, and both of its consumers trust it --
    # get_subscription_config bills amount_cents and _provision_tenant links the
    # id as the charge-time rate authority.
    #
    # The damage runs the wrong way from the obvious guess: forcing the most
    # expensive tier buys its LOWEST revenue share, so the platform cuts its own
    # take, and an attacker-chosen amount_cents bills nothing for the privilege.
    $t->post_ok("/run-data-test/${\ $run->id}/complete" => form => {
        'selected_pricing_plan[id]'           => '00000000-0000-0000-0000-0000000000ff',
        'selected_pricing_plan[amount_cents]' => 0,
        'selected_pricing_plan[plan_name]'    => 'Empire',
    })->status_is(201);

    ok !exists data_for($run->id)->{selected_pricing_plan},
        'a posted selected_pricing_plan is not stored';

    # The flat form too. The strip matches (?:\[|\z), and the \z branch is
    # load-bearing only for this key -- user_id and __tenant_slug are re-derived
    # immediately below it, so a bare posted value would be overwritten anyway.
    $run = run_on_second_step();
    $t->post_ok("/run-data-test/${\ $run->id}/complete" => form => {
        selected_pricing_plan => 'Empire',
    })->status_is(201);

    ok !exists data_for($run->id)->{selected_pricing_plan},
        'a posted selected_pricing_plan is not stored';
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
