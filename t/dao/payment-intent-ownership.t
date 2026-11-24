#!/usr/bin/env perl
# ABOUTME: A posted payment intent must belong to this payment row and match its price.
# ABOUTME: And a row that never took money must not be refundable.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Payment;
use Registry::Service::Stripe;
use Mojo::Promise;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_intent_ownership';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = $dao->create(User => {
    username => 'io_parent', name => 'IO Parent', user_type => 'parent',
    email => 'io@test.local' });

sub a_payment ($cents) {
    my $p = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => $cents, status => 'pending',
        metadata => { enrollment_items => [], tenant_slug => undef } });
    $db->update('payments', { stripe_payment_intent_id => 'pi_own_' . $p->id },
        { id => $p->id });
    return Registry::DAO::Payment->find($db, { id => $p->id });
}

sub status_of ($p) { $db->select('payments', ['status'], { id => $p->id })->hash->{status} }

# The posted intent id is client-controlled. Graded on its own, with no help
# from the amount guard: the foreign intent is priced EXACTLY like the target
# row, so the only thing that can refuse it is the ownership check.
subtest 'an intent belonging to another payment cannot settle this one' => sub {
    my $mine    = a_payment(200000);
    my $theirs  = a_payment(200000);

    my $forged = {
        id       => $theirs->stripe_payment_intent_id,
        status   => 'succeeded',
        amount   => 200000,
        metadata => { payment_id => $theirs->id },
    };

    my $out = $mine->_apply_intent($db, $forged, $forged->{id});

    is $out->{success}, 0, 'refused';
    like $out->{error}, qr/does not belong to this payment/,
        'and says why';
    is status_of($mine), 'pending',
        'the target row is untouched -- not completed';
    isnt status_of($mine), 'failed',
        'and a forged id cannot flip it to failed either';
    is $db->select('payments', ['stripe_payment_method_id'], { id => $mine->id })
        ->hash->{stripe_payment_method_id}, undef,
        'no payment method was copied across';
};

# The seller owns the account the return path retrieves from, so they can mint
# a succeeded intent stamped with our payment_id at our price. Metadata proves
# nothing; only the id Registry stored when it created the intent does.
subtest 'a seller-made intent stamped with our payment_id cannot settle it' => sub {
    my $stored   = a_payment(200000);
    my $unstored = a_payment(200000);
    $db->update('payments', { stripe_payment_intent_id => undef }, { id => $unstored->id });
    $unstored = Registry::DAO::Payment->find($db, { id => $unstored->id });

    for my $case ( [ 'a row with a stored intent' => $stored ],
                   [ 'a row with none stored'     => $unstored ] ) {
        my ( $name, $payment ) = @$case;
        my $minted = {
            id       => 'pi_seller_minted',
            status   => 'succeeded',
            amount   => 200000,
            metadata => { payment_id => $payment->id },
        };

        my $out = $payment->_apply_intent($db, $minted, $minted->{id});

        is $out->{success}, 0, "$name: refused";
        like $out->{error}, qr/does not belong to this payment/, "$name: and says why";
        is status_of($payment), 'pending', "$name: the row is not completed";
    }
};

# Graded on its own: this intent IS owned, so ownership passes and only the
# amount comparison can refuse it. Without both subtests, either guard alone
# would keep the other's mutant alive.
subtest 'an owned intent for the wrong amount cannot settle the row' => sub {
    my $payment = a_payment(200000);

    my $stale = {
        id       => $payment->stripe_payment_intent_id,
        status   => 'succeeded',
        amount   => 500,
        metadata => { payment_id => $payment->id },
    };

    my $out = $payment->_apply_intent($db, $stale, $stale->{id});

    is $out->{success}, 0, 'refused';
    like $out->{error}, qr/amount does not match/, 'and says why';
    is status_of($payment), 'pending',
        'a mismatch is a refusal, not a payment failure';
};

subtest 'the matching case still settles, so the guards are not just always-refuse' => sub {
    my $payment = a_payment(200000);

    my $good = {
        id             => $payment->stripe_payment_intent_id,
        status         => 'succeeded',
        amount         => 200000,
        payment_method => 'pm_ok',
        metadata       => { payment_id => $payment->id },
    };

    my $out = $payment->_apply_intent($db, $good, $good->{id});

    is $out->{success}, 1, 'accepted';
    is status_of($payment), 'completed', 'and the row completed';
};

# The allow-list is the only thing stopping a Stripe refund against a row that
# never took money. Asserted by the die, before any network call is reachable.
subtest 'a payment that never took money cannot be refunded' => sub {
    for my $status (qw( pending processing failed )) {
        my $payment = a_payment(200000);
        $db->update('payments',
            { status => $status, metadata => { -json => { refund_owed_cents => 5000 } } },
            { id => $payment->id });
        my $fresh = Registry::DAO::Payment->find($db, { id => $payment->id });

        my $err = do { local $@; eval { $fresh->refund_async($db, { amount_cents => 5000 }) }; $@ };
        like $err, qr/Cannot refund a payment with status '$status'/,
            "a $status row refuses to refund";
    }
};

subtest 'intent made on another tenant account is unreachable' => sub {
    $db->query( q{INSERT INTO registry.tenants (name, slug, stripe_connect_account_id)
                  VALUES ('Own A', 'own_a', 'acct_own_a'), ('Own B', 'own_b', 'acct_own_b')} );
    my $payment = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => 200000, status => 'pending',
        metadata => { enrollment_items => [], tenant_slug => 'own_a' } });
    $db->update('payments', { stripe_payment_intent_id => 'pi_on_a' }, { id => $payment->id });
    $payment = Registry::DAO::Payment->find($db, { id => $payment->id });

    # Stripe's own rule: an intent is visible only through the account it was
    # made on. Each call records the account that asked.
    my %intents = ( acct_own_a => 'pi_on_a', acct_own_b => 'pi_on_b' );
    my @asked;
    my $lookup = sub ($self, $intent_id) {
        push @asked, $self->stripe_account;
        die "No such payment_intent: '$intent_id'\n"
            unless ( $intents{ $self->stripe_account // '' } // '' ) eq $intent_id;
        return { id => $intent_id, status => 'processing', amount => 200000,
                 metadata => { payment_id => $payment->id } };
    };
    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent = $lookup;
    local *Registry::Service::Stripe::cancel_payment_intent_async =
        sub { Mojo::Promise->resolve( $lookup->(@_) ) };

    $payment->process_payment($db, 'pi_on_a');
    is $asked[-1], 'acct_own_a', 'retrieve goes through the payment\'s own account';

    my $cancel_error;
    $payment->stripe_client->cancel_payment_intent_async('pi_on_a')
        ->catch(sub ($e) { $cancel_error = $e })->wait;
    is $asked[-1], 'acct_own_a', 'cancel goes through the payment\'s own account';
    is $cancel_error, undef, 'and reaches its own intent';

    my $out = $payment->process_payment($db, 'pi_on_b');
    is $asked[-1], 'acct_own_a', 'a foreign intent id is still looked up on this payment\'s account';
    is $out->{success}, 0, "an intent made on tenant B's account is not reachable from A's payment";
    like $out->{error}, qr/No such payment_intent/, 'Stripe does not find it there';
};

# The seller account is server-owned: whatever a caller puts in metadata is
# discarded, and the account comes from the seller row named by tenant_slug.
subtest 'a planted seller account in payment metadata is never stored' => sub {
    require Test::Registry::Fixtures;
    my $seller = Test::Registry::Fixtures::platform_seller($db);
    my $stored = sub ($p) {
        Registry::DAO::Payment->find( $db, { id => $p->id } )->metadata->{stripe_account_id};
    };

    my $sold = Registry::DAO::Payment->create( $db, {
        user_id => $parent->id, amount_cents => 1000, status => 'pending',
        metadata => { enrollment_items => [], tenant_slug => $seller, stripe_account_id => 'acct_planted' } } );
    is $stored->($sold), 'acct_platform_test', "the seller row's account wins over the planted one";

    my $unsold = Registry::DAO::Payment->create( $db, {
        user_id => $parent->id, amount_cents => 1000, status => 'pending',
        metadata => { enrollment_items => [], tenant_slug => undef, stripe_account_id => 'acct_planted' } } );
    is $stored->($unsold), undef, 'with no seller, the planted account is dropped rather than kept';
};

done_testing;
