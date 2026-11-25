#!/usr/bin/env perl
# ABOUTME: The platform's subscription billing of tenants is gone, so its five columns leave every tenants table.
# ABOUTME: Covers registry, cloned tenant copies, tenants provisioned later, and a revert that restores the check.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use App::Sqitch;
use Test::PostgreSQL;
use Mojo::Pg;
use experimental 'signatures';

my $CHANGE  = 'drop-tenant-billing-columns';
my @BILLING = qw( stripe_customer_id stripe_subscription_id billing_status
                  trial_ends_at subscription_started_at );

my $pgsql = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri    = $pgsql->uri;
my $sqitch = App::Sqitch->new();

sub deploy ()  { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', $CHANGE ) }
sub revert ()  { $sqitch->run( 'sqitch', 'revert', '-t', $uri, '--to', "$CHANGE^", '-y' ) }

lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', "$CHANGE^" ) }
    'deploy to the parent change succeeds';

my $db = Mojo::Pg->new($uri)->db;

# A tenant cloned before the drop: its tenants copy carries the five columns.
sub provision ($slug) {
    $db->query( 'INSERT INTO registry.tenants (name, slug) VALUES (?, ?)', "Fixture $slug", $slug );
    $db->query( 'SELECT registry.clone_schema(?)', $slug );
}

# Billing columns still on a tenants table, as "schema.column".
sub billing_columns ( @schemas ) {
    return $db->query( q{
        SELECT table_schema || '.' || column_name AS c
          FROM information_schema.columns
         WHERE table_name = 'tenants' AND column_name = ANY(?)
           AND (table_schema = ANY(?) OR ? = 0)
         ORDER BY 1
    }, \@BILLING, \@schemas, scalar @schemas )->arrays->map( sub { $_->[0] } )->to_array;
}

provision('before_drop');

# Payers' Stripe customers are recorded on payments' metadata in each tenant
# schema, never on tenants; the drop must leave them alone.
my $payer = $db->query(
    q{INSERT INTO registry.users (username) VALUES ('billing-drop-payer') RETURNING id})->hash->{id};
$db->query( q{INSERT INTO before_drop.users (id, username) VALUES (?, 'billing-drop-payer')}, $payer );
my $payment = $db->query( q{
    INSERT INTO before_drop.payments (user_id, amount_cents, status, metadata)
    VALUES (?, 1000, 'completed', '{"stripe_customer_id": "cus_payer"}') RETURNING id
}, $payer )->hash->{id};

my $other_customer_columns = sub {
    $db->query( q{
        SELECT table_schema || '.' || table_name AS t FROM information_schema.columns
         WHERE column_name = 'stripe_customer_id' AND table_name <> 'tenants' ORDER BY 1
    } )->arrays->map( sub { $_->[0] } )->to_array;
};
my $before_customer_columns = $other_customer_columns->();

subtest 'deploy tolerates partially missing columns' => sub {
    provision('partial_copy');
    $db->query('ALTER TABLE partial_copy.tenants DROP COLUMN billing_status, DROP COLUMN trial_ends_at');

    lives_ok { deploy() } 'the drop deploys over a tenants copy already missing some columns';
    is_deeply billing_columns('partial_copy'), [], 'and that copy ends with none of them';
};

subtest 'no tenants table carries billing columns' => sub {
    is_deeply billing_columns(), [], 'neither registry nor any tenant schema keeps one';
    is_deeply billing_columns( 'registry', 'before_drop' ), [],
        'including the copy cloned before the drop';
};

subtest 'tenant provisioned after drop lacks billing columns' => sub {
    provision('after_drop');
    is_deeply billing_columns('after_drop'), [], 'clone_schema copies the dropped shape';
};

subtest 'stripe_customer_id survives on families users payments' => sub {
    is $db->query( q{SELECT metadata->>'stripe_customer_id' AS c FROM before_drop.payments WHERE id = ?},
        $payment )->hash->{c}, 'cus_payer', "a payer's Stripe customer on a payment is kept";
    is_deeply $other_customer_columns->(), $before_customer_columns,
        'and no stripe_customer_id column outside tenants is dropped';
};

subtest 'revert restores billing_status check' => sub {
    lives_ok { revert() } 'the revert runs';

    is_deeply billing_columns( 'registry', 'before_drop', 'after_drop' ),
        [ sort map { my $s = $_; map {"$s.$_"} @BILLING } qw( registry before_drop after_drop ) ],
        'the five columns are back on registry and every tenant copy';

    for my $schema (qw( registry after_drop )) {
        throws_ok {
            $db->query( "INSERT INTO $schema.tenants (name, slug, billing_status) VALUES ('Bad', 'bad_status', 'overdue')" )
        } qr/tenants_billing_status_check/, "$schema refuses an invalid billing_status";
    }
    is $db->query( q{INSERT INTO registry.tenants (name, slug) VALUES ('Default', 'reverted_default')
                     RETURNING billing_status} )->hash->{billing_status}, 'trial',
        'with its original default';

    lives_ok { deploy() } 'and the change deploys again';
};

done_testing;
