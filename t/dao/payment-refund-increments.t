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

# THE invariant, across settlements rather than within one. Every quantity is a
# different number, because a fixture where two coincide cannot say which one
# the code used -- that is how the balance-vs-increment mutant survived a full
# pass on this branch.
#
# The clamp used to read amount_cents - refund_owed_cents, with no refunded_cents
# term. Settling drives refund_owed_cents to zero, so every discharge handed the
# whole headroom back and the increments could total more than the cart.
subtest 'settled money is spent headroom, and never becomes refundable again' => sub {
    my $p = a_payment(9000);

    $p->record_capacity_obligation( $db, 6000, ['child-a'] );
    $p->settle_refund_increment( $db, 1, { id => 're_one' } );
    is row_of($p)->{refunded_cents}, 6000, '6000 of a 9000 cart has gone back';
    is row_of($p)->{refund_owed_cents}, 0, 'and nothing is owed';

    # Only 3000 of the cart is still refundable. Asking for 5000 must yield 3000.
    $p->record_capacity_obligation( $db, 5000, ['child-b'] );

    my $r = row_of($p);
    is $r->{refund_owed_cents}, 3000,
        'the second debt is clamped to what is left, not to the whole cart';

    my $summed = 0;
    $summed += $_->{cents} for @{ $r->{refund_increments} };
    is $summed, $r->{refunded_cents} + $r->{refund_owed_cents},
        'increments account for every cent, returned or owed';
    cmp_ok $summed, '<=', 9000,
        'and never total more than the charge -- 11000 against 9000 was the defect';
};

subtest 'a fully refunded charge cannot take on new debt' => sub {
    my $p = a_payment(9000);
    $p->record_capacity_obligation( $db, 9000, ['child-a'] );
    $p->settle_refund_increment( $db, 1, { id => 're_all' } );
    is row_of($p)->{status}, 'refunded', 'the whole cart went back';

    $p->record_capacity_obligation( $db, 2500, ['child-b'] );

    my $r = row_of($p);
    is $r->{refund_owed_cents}, 0, 'no further debt is recordable';
    is $r->{status}, 'refunded',
        'and the terminal status is not dragged back to refund_pending';
    is $r->{refund_seq}, 1,
        'the counter does not advance for a debt that was never recorded';
    is scalar @{ $r->{refund_increments} }, 1,
        'and no zero-cent increment is appended -- the caller would POST amount=0';
    ok $r->{metadata}{refund_manual_review},
        'the debt that could not be recorded is flagged, not dropped in silence';
};

# A negative delta subtracts. A large one violates
# payments_refund_owed_cents_check INSIDE the settlement transaction, which
# rolls back a charge Stripe has already captured -- the exact outcome the
# clamp exists to prevent. Reachable through an unbounded percentage_discount
# on a pricing plan, which yields a negative share.
subtest 'a negative share is refused, not subtracted' => sub {
    my $p = a_payment(9000);
    $p->record_capacity_obligation( $db, 6000, ['child-a'] );

    my $err = do { local $@; eval { $p->record_capacity_obligation( $db, -2500, ['child-b'] ); 1 }; $@ };
    is $err, '', 'it does not throw inside the settlement transaction';

    my $r = row_of($p);
    is $r->{refund_owed_cents}, 6000, 'and does not reduce a real debt';
    is scalar @{ $r->{refund_increments} }, 1, 'no negative increment is recorded';
    ok $r->{metadata}{refund_manual_review},
        'the nonsense share is flagged for a human instead of being swallowed';
};

# _apply_refund_result owns the status and the cumulative total for a DIRECT
# refund -- one with no per-increment idempotency key. Every other assertion in
# the suite sits on the settle_refund_increment path, so this branch was
# ungraded, and it accumulates rather than assigns.
subtest 'a direct refund records itself, and a second one adds to the first' => sub {
    my $p = a_payment(10000);

    my $apply = sub ($cents) {
        $p->_apply_refund_result( $db, { id => "re_direct_$cents" }, $cents, 'requested_by_customer', 0 );
    };

    $apply->(2000);
    my $r = row_of($p);
    is $r->{refunded_cents}, 2000, 'the first direct refund is recorded';
    is $r->{status}, 'partially_refunded', 'and the status follows it';

    $apply->(1500);
    $r = row_of($p);
    is $r->{refunded_cents}, 3500,
        'the second accumulates rather than overwriting -- assigning lost the first';
    is $r->{status}, 'partially_refunded', 'still partial';

    $apply->(6500);
    is row_of($p)->{status}, 'refunded',
        'and the cart reads fully refunded once the total reaches it';
};

# The guard used to be "does this row have any increments", which latched
# permanently on the first capacity demotion -- so a later direct refund left
# the bank while the ledger denied it.
subtest 'a direct refund on a payment that once had an increment is still recorded' => sub {
    my $p = a_payment(10000);
    $p->record_capacity_obligation( $db, 2000, ['child-a'] );
    $p->settle_refund_increment( $db, 1, { id => 're_inc' } );
    is row_of($p)->{refunded_cents}, 2000, 'the increment is settled';

    $p->_apply_refund_result( $db, { id => 're_after' }, 3000, 'requested_by_customer', 0 );

    is row_of($p)->{refunded_cents}, 5000,
        'a later direct refund is still recorded, not swallowed by a latched guard';
};

done_testing;
