#!/usr/bin/env perl
# ABOUTME: payments and payment_items store money as integer cents, so the
# ABOUTME: amount charged is the amount stored with no conversion in between.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Payment;
use Registry::DAO::User;
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

$db->query("SET search_path TO registry, public");

my $user = Registry::DAO::User->create($db, {
    username => 'centsuser',
    email    => 'cents@example.com',
    password => 'password123',
    name     => 'Cents User',
});

subtest 'the money columns are integer cents, and the dollars columns are gone' => sub {
    my $cols = $db->query(q{
        SELECT table_name, column_name, data_type
          FROM information_schema.columns
         WHERE table_schema = 'registry'
           AND table_name IN ('payments', 'payment_items')
           AND column_name IN ('amount', 'amount_cents')
    })->hashes->reduce(sub { $a->{ "$b->{table_name}.$b->{column_name}" } = $b->{data_type}; $a }, {});

    is $cols->{'payments.amount_cents'}, 'integer',
        'payments.amount_cents is a true integer';
    ok !exists $cols->{'payments.amount'},
        'payments lost the dollars column';

    is $cols->{'payment_items.amount_cents'}, 'integer',
        'payment_items.amount_cents is a true integer';
    ok !exists $cols->{'payment_items.amount'},
        'payment_items lost the dollars column';
};

subtest 'a tenant schema gets the new shape too' => sub {
    # clone_schema copies registry's structure, so new tenants follow for free.
    # Tenants that already exist do not, and a tenant still on the dollars
    # column would charge in the wrong units for every family it serves.
    Test::Registry::Fixtures::create_tenant($db, {
        name => 'Payment Cents Tenant',
        slug => 'payment_cents',
    });
    $db->query('SELECT clone_schema(?)', 'payment_cents');

    my $cols = $db->query(q{
        SELECT table_name, column_name
          FROM information_schema.columns
         WHERE table_schema = 'payment_cents'
           AND table_name IN ('payments', 'payment_items')
           AND column_name IN ('amount', 'amount_cents')
    })->hashes->reduce(sub { $a->{ "$b->{table_name}.$b->{column_name}" } = 1; $a }, {});

    ok $cols->{'payments.amount_cents'},       'tenant payments has amount_cents';
    ok !$cols->{'payments.amount'},            'tenant payments lost the dollars column';
    ok $cols->{'payment_items.amount_cents'},  'tenant payment_items has amount_cents';
    ok !$cols->{'payment_items.amount'},       'tenant payment_items lost the dollars column';
};

subtest 'a payment round-trips as an integer, not a decimal string' => sub {
    my $payment = Registry::DAO::Payment->create($db, {
        user_id      => $user->id,
        amount_cents => 1999,
    });

    is $payment->amount_cents, 1999, '$19.99 is stored as 1999 cents';

    my $reloaded = Registry::DAO::Payment->find($db, { id => $payment->id });
    is $reloaded->amount_cents, 1999, 'and reads back as 1999';
    is $reloaded->amount_cents, int($reloaded->amount_cents),
        'with no fractional part the driver could stringify';
};

subtest 'line items are cents too' => sub {
    my $payment = Registry::DAO::Payment->create($db, {
        user_id      => $user->id,
        amount_cents => 20_000,
    });

    $payment->add_line_item($db, {
        description  => 'Child 1 - Session 1',
        amount_cents => 10_000,
    });
    $payment->add_line_item($db, {
        description  => 'Child 2 - Session 1',
        amount_cents => 10_000,
    });

    my $items = $payment->line_items($db);
    is scalar(@$items), 2, 'both line items saved';
    is $items->[0]{amount_cents}, 10_000, 'first item is 10000 cents';
    is $items->[1]{amount_cents}, 10_000, 'second item is 10000 cents';
};

subtest 'nothing converts dollars to cents anymore' => sub {
    # _to_cents existed to undo DBD::Pg handing back a DECIMAL as a string.
    # With the column an integer there is nothing to undo, and leaving the
    # helper as an identity function would invite a caller to feed it dollars.
    ok !Registry::DAO::Payment->can('_to_cents'),
        'the dollars-to-cents helper is gone';
};

subtest 'the charged amount is the stored amount' => sub {
    # $19.99 is the canonical case: "19.99" numified and truncated billed 1998.
    # With cents stored directly the intent carries 1999 because that is the
    # number in the row, not because a rounding rule got it right.
    my $payment = Registry::DAO::Payment->create($db, {
        user_id      => $user->id,
        amount_cents => 1999,
    });

    my $params = $payment->_intent_params($db, {});
    is $params->{amount}, 1999, 'the intent charges exactly the stored cents';
};

subtest 'an enrollment total stays in cents end to end' => sub {
    # calculate_enrollment_total read a cents price from the pricing plan and
    # divided by 100 to meet a dollars column. That division is the last place
    # a cent could go missing between the plan and the charge.
    my $session = Registry::DAO::Session->create($db, { name => 'Cents Session' });
    Registry::DAO::PricingPlan->create($db, {
        session_id   => $session->id,
        plan_name    => 'Standard',
        amount_cents => 1999,
    });

    my $info = Registry::DAO::Payment->calculate_enrollment_total($db, {
        children => [
            { id => 'child-a', first_name => 'Ada',  last_name => 'Byron' },
            { id => 'child-b', first_name => 'Alan', last_name => 'Turing' },
        ],
        session_selections => { 'child-a' => $session->id, 'child-b' => $session->id },
    });

    is $info->{total}, 3998, 'two enrollments at $19.99 total 3998 cents';
    is scalar(@{ $info->{items} }), 2, 'two line items';
    is $info->{items}[0]{amount_cents}, 1999, 'each item carries cents';
};

done_testing;
