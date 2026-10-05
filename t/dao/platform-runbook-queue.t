#!/usr/bin/env perl
# ABOUTME: Every payment with an unpaid obligation is findable, including the ones nobody decided about.
# ABOUTME: A family can be waitlisted, owed money, and invisible; this is the reader that ends that.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Tenant;
use Registry::DAO::Payment;
use Registry::DAO::User;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $studio = Test::Registry::Fixtures::create_tenant( $db, {
    name => 'Owing Studio', slug => 'owing_studio' } );

my $parent = $dao->create( User => {
    username => 'rb_parent', name => 'Runbook Parent', user_type => 'parent',
    email => 'rb@test.local' } );

# The payer must be resident in the tenant schema: <tenant>.payments.user_id
# references <tenant>.users. copy_user is not idempotent, so once only.
$db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)',
    'owing_studio', $parent->id );
my $tdb = $dao->connect_schema('owing_studio')->db;

# Obligations live in <tenant>.payments, like every other payment column.
sub a_payment ( %col ) {
    my $p = Registry::DAO::Payment->create( $tdb, {
        user_id      => $parent->id,
        amount_cents => delete $col{amount_cents} // 10000,
        status       => delete $col{status}       // 'completed',
        metadata     => delete $col{metadata}     // { enrollment_items => [] },
    } );
    $tdb->update( 'payments', \%col, { id => $p->id } ) if %col;
    return $p;
}

# 1. Money still owed. refund_owed_cents is what is LEFT owed -- settling
#    decrements it -- so a non-zero value is an outstanding debt.
my $owed = a_payment(
    status            => 'refund_pending',
    refund_owed_cents => 4000,
    refunded_cents    => 1000,
);

# 2. Nothing computable left owed, but an unresolved manual-review flag holds
#    the row. Payment.pm:1356 is explicit that these are the runbook's rows and
#    that it finds them BY STATUS -- a reader keyed on refund_owed_cents alone
#    would miss exactly the rows nobody has decided about.
my $undecided = a_payment(
    status            => 'refund_pending',
    refund_owed_cents => 0,
    # A plain hashref: Payment->create wraps metadata in -json itself, so
    # wrapping it here lands a literal "-json" key inside the stored JSON.
    metadata          => {
        enrollment_items     => [],
        refund_manual_review => [ { child_id => 'someone', session_id => undef } ],
    },
);

# 3. Settled: owed driven to zero, money returned, terminal status. Not a
#    runbook row, and must not be dressed up as one.
my $settled = a_payment(
    status            => 'refunded',
    refund_owed_cents => 0,
    refunded_cents    => 10000,
);

# 4. An ordinary completed charge with no obligation at all.
my $clean = a_payment( status => 'completed' );

subtest 'a debt still owed is found, with what is outstanding' => sub {
    my $q = Registry::DAO::Tenant->unpaid_obligations($db);
    my %by_id = map { $_->{payment_id} => $_ } @{ $q->{payments} };

    my $row = $by_id{ $owed->id };
    ok $row, 'the payment with money still owed is in the queue';
    is $row->{refund_owed_cents}, 4000, 'the outstanding amount is reported';
    is $row->{tenant_slug}, 'owing_studio', 'attributed to its tenant';
    is $row->{payer_name}, 'Runbook Parent',
        'and names the family, since the runbook has to contact them';
};

subtest 'a row nobody has decided about is found too' => sub {
    my $q = Registry::DAO::Tenant->unpaid_obligations($db);
    my %by_id = map { $_->{payment_id} => $_ } @{ $q->{payments} };

    my $row = $by_id{ $undecided->id };
    ok $row, 'refund_pending with zero computable debt is still a runbook row';
    is $row->{refund_owed_cents}, 0, 'nothing is computably owed';
    is $row->{manual_review}, 1,
        'but a share nobody could work out is counted, which is why it is here';
};

subtest 'settled and clean payments are not in the queue' => sub {
    my $q = Registry::DAO::Tenant->unpaid_obligations($db);
    my %by_id = map { $_->{payment_id} => $_ } @{ $q->{payments} };

    ok !$by_id{ $settled->id }, 'a fully refunded payment is not outstanding';
    ok !$by_id{ $clean->id },   'nor is an ordinary completed charge';
};

subtest 'the queue totals what is owed, so it can be read at a glance' => sub {
    my $q = Registry::DAO::Tenant->unpaid_obligations($db);

    is $q->{owed_cents}, 4000, 'the total still owed across every tenant';
    is scalar @{ $q->{payments} }, 2,
        'two rows need a human: one owed money, one undecided';
};

subtest 'a tenant whose schema cannot be read is named, not skipped silently' => sub {
    Registry::DAO::Tenant->create( $db, {
        name => 'Half Provisioned', slug => 'half_runbook' } );
    $db->query('CREATE SCHEMA IF NOT EXISTS half_runbook');

    my $q = Registry::DAO::Tenant->unpaid_obligations($db);
    my ($named) = grep { $_->{slug} eq 'half_runbook' } @{ $q->{unreadable} };
    ok $named, 'the unreadable tenant is named';
    like $named->{error}, qr/\S/, 'with the reason';

    is $q->{owed_cents}, 4000,
        'and the readable tenants are still totalled';
};

done_testing;
