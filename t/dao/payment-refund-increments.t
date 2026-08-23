#!/usr/bin/env perl
# ABOUTME: Each debt increment is refunded once, under its own stable key, and retried until settled.
# ABOUTME: Refunding the accumulated balance under a fresh key is how one debt gets paid twice.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Payment;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_refund_increments';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = $dao->create(User => {
    username => 'ri_parent', name => 'RI Parent', user_type => 'parent',
    email => 'ri@test.local' });

sub a_payment ($cents = 20000) {
    Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => $cents, status => 'pending',
        metadata => { enrollment_items => [], tenant_slug => undef } });
}

sub row_of ($p) {
    $db->select('payments', '*', { id => $p->id })->expand->hash;
}

subtest 'each increment gets its own row, its own key, and its own amount' => sub {
    my $p = a_payment();
    $p->record_capacity_obligation( $db, 5000, ['child-a'] );

    my $r = row_of($p);
    is $r->{refund_owed_cents}, 5000, 'the balance is the typed column, not jsonb';
    is $r->{refund_seq}, 1, 'the counter advanced';
    is scalar @{ $r->{refund_increments} }, 1, 'one increment recorded';
    is $r->{refund_increments}[0]{cents}, 5000, 'carrying its own amount';
    is $r->{refund_increments}[0]{settled_at}, undef, 'and unsettled';

    $p->record_capacity_obligation( $db, 3000, ['child-b'] );

    $r = row_of($p);
    is $r->{refund_owed_cents}, 8000, 'the balance accumulates';
    is scalar @{ $r->{refund_increments} }, 2, 'the second increment is its own row';
    is $r->{refund_increments}[1]{cents}, 3000,
        'recording the DELTA, not the running total -- sending the total under a '
        . 'fresh key is the double refund';
};

# The defect, stated as a test. Increment 1 is sent and its response is lost, so
# it stays unsettled. A second child is then demoted. The old code refunded the
# whole 8000 balance under a key derived from the child set -- which had grown,
# so Stripe saw a key it had never seen and paid again: 13000 against 8000 owed.
subtest 'a lost response does not make the next attempt re-send the first amount' => sub {
    my $p = a_payment();
    $p->record_capacity_obligation( $db, 5000, ['child-a'] );
    $p->record_capacity_obligation( $db, 3000, ['child-b'] );

    my @due = @{ $p->unsettled_refund_increments($db) };
    is scalar @due, 2, 'both increments are due';
    is_deeply [ map { $_->{cents} } @due ], [ 5000, 3000 ],
        'and each is due for its own amount';

    my $total = 0; $total += $_->{cents} for @due;
    is $total, 8000, 'the total that would reach Stripe equals the debt, not more';

    my @keys = map { $p->capacity_refund_key( $_->{seq} ) } @due;
    is_deeply \@keys, [ "refund:capacity:@{[ $p->id ]}:1",
                        "refund:capacity:@{[ $p->id ]}:2" ],
        'each carries a key naming its own increment';
    isnt $keys[0], $keys[1], 'so Stripe can never fold one into the other';
};

subtest 'settling one increment leaves the others owed and retryable' => sub {
    my $p = a_payment();
    $p->record_capacity_obligation( $db, 5000, ['child-a'] );
    $p->record_capacity_obligation( $db, 3000, ['child-b'] );

    $p->settle_refund_increment( $db, 2, { id => 're_two' } );

    my $r = row_of($p);
    is $r->{refund_owed_cents}, 5000,
        'the balance is REDUCED by what was paid, not deleted -- a debt that '
        . 'grew during the round trip used to be erased whole';
    is $r->{refunded_cents}, 3000, 'and the cumulative total returned is recorded';

    my @due = @{ $p->unsettled_refund_increments($db) };
    is scalar @due, 1, 'the unpaid increment is still due';
    is $due[0]{seq}, 1, 'and it is the right one';
    is $p->capacity_refund_key(1), "refund:capacity:@{[ $p->id ]}:1",
        'retried under the SAME key it was first sent with';
};

subtest 'settling the last increment clears the debt and the status' => sub {
    my $p = a_payment();
    $p->record_capacity_obligation( $db, 5000, ['child-a'] );
    is row_of($p)->{status}, 'refund_pending', 'a debt marks the row';

    $p->settle_refund_increment( $db, 1, { id => 're_one' } );

    my $r = row_of($p);
    is $r->{refund_owed_cents}, 0, 'nothing owed';
    is $r->{refunded_cents}, 5000, 'all of it returned';
    is scalar @{ $p->unsettled_refund_increments($db) }, 0, 'nothing due';
    is $r->{status}, 'partially_refunded',
        'and a part-refunded cart says so rather than claiming a full refund';
};

subtest 'settling an increment twice does not double-count the money returned' => sub {
    my $p = a_payment();
    $p->record_capacity_obligation( $db, 5000, ['child-a'] );
    $p->settle_refund_increment( $db, 1, { id => 're_one' } );
    $p->settle_refund_increment( $db, 1, { id => 're_one' } );

    my $r = row_of($p);
    is $r->{refunded_cents}, 5000, 'counted once';
    is $r->{refund_owed_cents}, 0, 'and not driven negative past the CHECK';
};

# The increments are what actually reach Stripe, so if the balance is clamped
# against payments_refund_owed_cents_check but the increments are not, the
# refunds sent exceed the payment. They must clamp against the same headroom.
subtest 'a debt larger than the cart clamps the increment, not just the balance' => sub {
    my $p = a_payment(10000);
    $p->record_capacity_obligation( $db, 8000, ['child-a'] );
    $p->record_capacity_obligation( $db, 8000, ['child-b'] );

    my $r = row_of($p);
    is $r->{refund_owed_cents}, 10000, 'the balance stops at the cart total';

    my $summed = 0;
    $summed += $_->{cents} for @{ $r->{refund_increments} };
    is $summed, $r->{refund_owed_cents},
        'and the increments sum to it exactly -- what is sent equals what is owed';
    cmp_ok $summed, '<=', 10000, 'never more than the payment itself';
};

done_testing;
