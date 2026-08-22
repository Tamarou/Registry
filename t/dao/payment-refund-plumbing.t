#!/usr/bin/env perl
# ABOUTME: A refund_pending payment can be refunded, and a refund carries an idempotency key.
# ABOUTME: A per-child refund returns that child's share of a family cart, not the whole cart.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Async qw( settle );
use Registry::DAO::Payment;
use Registry::Service::Stripe;
use Mojo::Promise;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_refund_plumbing';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = $dao->create(User => {
    username => 'rp_parent', name => 'RP Parent', user_type => 'parent',
    email => 'rp@test.local',
});

sub payment_with ($status) {
    my $p = Registry::DAO::Payment->create($db, {
        user_id => $parent->id,
        amount_cents => 15000,
        status => $status,
        metadata => { enrollment_items => [], tenant_slug => undef },
    });
    # A completed payment has an intent; the guards check for one separately.
    $db->update('payments', { stripe_payment_intent_id => 'pi_rp_' . $p->id },
        { id => $p->id });
    return Registry::DAO::Payment->find($db, { id => $p->id });
}

# A family cart: two children, different prices, one session each.
sub cart_items_for ($payment, @rows) {
    for my $row (@rows) {
        $db->insert('payment_items', {
            payment_id   => $payment->id,
            description  => $row->{desc},
            amount_cents => $row->{cents},
            metadata     => { -json => {
                child_id   => $row->{child},
                session_id => $row->{session},
            } },
        });
    }
}

subtest 'the refund guards are an allow-list of completed and refund_pending' => sub {
    for my $status (qw( completed refund_pending )) {
        my $async = payment_with($status);

        my $async_ok = eval {
            no warnings 'redefine';
            local *Registry::Service::Stripe::create_refund_async =
                sub ($s, $p) { Mojo::Promise->resolve({ id => 're_ok', status => 'succeeded' }) };
            settle( $async->refund_async($db) );
            1;
        };
        ok $async_ok, "refund_async accepts a $status payment" or diag $@;
    }
};

subtest 'the allow-list has not become anything' => sub {
    # Task 5b writes refund_pending and immediately refunds; widening the guard
    # far enough to let that through must not also let through a row that was
    # never charged.
    for my $status (qw( pending failed processing )) {
        my $payment = payment_with($status);
        my $ok = eval { settle( $payment->refund_async($db) ); 1 };
        ok !$ok, "refund_async still refuses a $status payment";
    }
};

subtest 'a refund carries an idempotency key and does not post it as a form field' => sub {
    my $payment = payment_with('completed');
    my %captured;
    my $captured_key;

    no warnings 'redefine';
    # _request_async is where the key and the form body part company: the key
    # becomes a header, the body must not carry it. Stripe 400s on unknown form
    # parameters, so a leaked _idempotency_key fails the whole refund.
    local *Registry::Service::Stripe::_request_async = sub ($s, $method, $path, $params = undef, $ik = undef) {
        %captured     = %{ $params // {} };
        $captured_key = $ik;
        return Mojo::Promise->resolve({ id => 're_key', status => 'succeeded' });
    };

    settle( $payment->refund_async($db, { idempotency_key => 'refund:capacity:abc' }) );

    is $captured_key, 'refund:capacity:abc', 'the key reaches the request layer';
    ok !exists $captured{_idempotency_key},
        'and is deleted from the form body before the POST';
    ok exists $captured{payment_intent}, 'the real refund params survive';
};

subtest 'a per-child refund returns that child share, not the family cart' => sub {
    my $payment = payment_with('completed');
    cart_items_for($payment,
        { desc => 'Kid A - Week 1', cents => 10000, child => 'child-a', session => 'sess-1' },
        { desc => 'Kid B - Week 1', cents =>  5000, child => 'child-b', session => 'sess-1' },
    );

    is $payment->refund_share_for($db, 'child-a', 'sess-1'), 10000,
        "one child's share is that child's line item";
    is $payment->refund_share_for($db, 'child-b', 'sess-1'), 5000,
        'and the sibling has their own, smaller share';
    isnt $payment->refund_share_for($db, 'child-b', 'sess-1'), $payment->amount_cents,
        'neither is the cart total -- refunding the payment would return both';
};

subtest 'the share resolver refuses rather than falling back to the cart' => sub {
    my $payment = payment_with('completed');
    cart_items_for($payment,
        { desc => 'Kid A - Week 1', cents => 10000, child => 'child-a', session => 'sess-1' },
    );

    # A silent fallback to the cart total here refunds every sibling's money for
    # one child's lost seat, which is the whole reason this resolver exists.
    my $ok = eval { $payment->refund_share_for($db, 'child-nobody', 'sess-1'); 1 };
    ok !$ok, 'an unmatched child refuses';
    like $@, qr/no line item/i, 'and says why';

    my $ok2 = eval { $payment->refund_share_for($db, 'child-a', 'sess-nowhere'); 1 };
    ok !$ok2, 'an unmatched session refuses too';
};

done_testing;
