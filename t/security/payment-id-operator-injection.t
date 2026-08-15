#!/usr/bin/env perl
# ABOUTME: Proves a client-planted operator hashref in run data's payment_id cannot reach a WHERE clause.
# ABOUTME: A bracketed form param expands to { '!=' => ... }, which SQL::Abstract renders as an operator.
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
use Registry::DAO::Payment;
use Registry::DAO::WorkflowSteps::Payment;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Injection Test Tenant',
    slug => 'test_injection',
});
$dao->db->query('SELECT clone_schema(?)', 'test_injection');

$dao = Registry::DAO->new(url => $test_db->uri, schema => 'test_injection');
my $db = $dao->db;

my $parent = Registry::DAO::User->create($db, {
    name      => 'Test Parent',
    username  => 'testparent',
    email     => 'parent@example.com',
    user_type => 'parent',
});

my $workflow = Registry::DAO::Workflow->create($db, {
    name        => 'Injection Test Workflow',
    slug        => 'injection-test-workflow',
    description => 'Landing passthrough followed by the payment step',
});

# The landing step is a bare WorkflowStep with no outcome definition, so
# validate() is a no-op and process() persists whatever the client posted.
my $landing = Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id,
    slug        => 'landing',
    class       => 'Registry::DAO::WorkflowStep',
    description => 'Landing',
});
my $payment_step_row = Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id,
    slug        => 'payment',
    class       => 'Registry::DAO::WorkflowSteps::Payment',
    description => 'Payment',
    depends_on  => $landing->id,
});
Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id,
    slug        => 'complete',
    class       => 'Registry::DAO::WorkflowStep',
    description => 'Complete',
    depends_on  => $payment_step_row->id,
});
$workflow->update($db, { first_step => 'landing' }, { id => $workflow->id });

my $payment_step = $workflow->get_step($db, { slug => 'payment' });

# An unrelated payment belonging to this tenant, with one line item.
sub make_victim {
    my $victim = Registry::DAO::Payment->create($db, {
        user_id      => $parent->id,
        amount_cents => 5000,
        metadata     => {},
    });
    $victim->add_line_item($db, {
        description  => 'Someone else tuition',
        amount_cents => 5000,
    });
    return $victim;
}

# Plant the operator hashref exactly the way an unauthenticated GET/POST would:
# payment_id[!=]=<uuid> expands to payment_id => { '!=' => <uuid> }.
sub planted_run {
    my $run = $workflow->new_run($db);
    $run->process($db, $landing, {
        'payment_id[!=]' => '00000000-0000-0000-0000-000000000000',
    });
    $run->update_data($db, { user_id => $parent->id });
    return $run;
}

subtest 'the operator hashref really does land in run data' => sub {
    my $run = planted_run();
    is ref $run->data->{payment_id}, 'HASH',
        'bracketed param expands to a hashref in run data';
    is $run->data->{payment_id}{'!='}, '00000000-0000-0000-0000-000000000000',
        'and carries the operator the client chose';
};

subtest 'create_payment refuses a non-scalar payment_id' => sub {
    my $victim = make_victim();
    my $run    = planted_run();

    my $ok = eval { $payment_step->create_payment($db, $run, {}); 1 };
    my $err = $@;

    ok !$ok, 'create_payment dies instead of binding a hashref into WHERE';
    like $err, qr/payment_id/, 'error names the offending key';

    my $row = $db->select('payments', '*', { id => $victim->id })->hash;
    is $row->{amount_cents}, 5000, 'unrelated payment amount untouched';
    is $db->select('payment_items', '*', { payment_id => $victim->id })->rows, 1,
        'unrelated payment line items untouched';
};

subtest 'handle_payment_callback refuses a non-scalar payment_id' => sub {
    my $victim = make_victim();
    my $run    = planted_run();

    my $ok = eval {
        $payment_step->handle_payment_callback($db, $run, {
            payment_intent_id => 'pi_never_sent',
        });
        1;
    };
    my $err = $@;

    ok !$ok, 'handle_payment_callback dies before looking up a payment';
    like $err, qr/payment_id/, 'error names the offending key';
};

done_testing;
