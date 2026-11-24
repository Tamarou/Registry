# ABOUTME: Building intent params must make no blocking Stripe call, because the request path runs inside a live IOLoop.
# ABOUTME: An instalment charge needs a Stripe customer, and fetching one synchronously there can never settle.
#
# Mojo::Promise::wait opens with `return if $self->ioloop->is_running`, so a
# blocking Stripe call inside a running loop never settles and
# Service::Stripe::_await dies. create_payment_intent_async is the request path,
# but it builds its params SYNCHRONOUSLY before any promise exists -- so a
# network call reached from _intent_params happens in the live loop. No other
# test could see this: under plain `prove` no loop is running, which is exactly
# the condition that makes ->wait work. See #284.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';

use Mojo::IOLoop;
use Mojo::Promise;

use Test::Registry::DB;
use Test::Registry::PricingProbe qw( give_tenant_terms state_platform_terms );
use Test::Registry::Fixtures;
use Registry::DAO;
use Registry::DAO::User;
use Registry::DAO::Payment;
use Registry::Service::Stripe;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_intent_customer';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $slug = 'instal_async';
Test::Registry::Fixtures::create_tenant( $db, {
    name => 'Instalment Studio', slug => $slug } );

my $parent = $dao->create( User => {
    username => 'instal_parent', user_type => 'parent',
    email => 'instal@test.example', name => 'Ida Instalment' } );

$db->query( 'UPDATE registry.tenants SET stripe_connect_account_id = ? WHERE slug = ?',
    'acct_instal_seller', $slug );
state_platform_terms( $db, $slug, { rate => 0 } );

# Payments live in the tenant schema; the payer must be resident there first.
$db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)', $slug, $parent->id );
my $tdb = $dao->connect_schema($slug)->db;

# Resolve on the next tick, the way a real network promise does. Resolving
# immediately would hide the defect: ->wait would find it already settled.
sub deferred ($value) {
    my $p = Mojo::Promise->new;
    Mojo::IOLoop->next_tick( sub { $p->resolve($value) } );
    return $p;
}

# Runs $code inside a running loop, the condition a web request creates.
sub in_running_loop ($code) {
    my ( $resolved, $error, $not_a_promise );

    Mojo::IOLoop->next_tick( sub {
        my $p = eval { $code->() };
        if ($@) { $error = $@; Mojo::IOLoop->stop; return }
        unless ( ref $p && $p isa Mojo::Promise ) {
            $not_a_promise = $p // '(undef)';
            Mojo::IOLoop->stop;
            return;
        }
        $p->then( sub { $resolved = shift } )
          ->catch( sub { $error = shift } )
          ->finally( sub { Mojo::IOLoop->stop } );
    } );

    # Without this a call that never settles hangs the suite rather than failing.
    my $guard = Mojo::IOLoop->timer( 10 => sub {
        $error //= 'timed out waiting for the intent to settle';
        Mojo::IOLoop->stop;
    } );

    Mojo::IOLoop->start;
    Mojo::IOLoop->remove($guard);

    $error //= "got a non-promise ($not_a_promise) instead of a deferral"
        if defined $not_a_promise;

    return ( $resolved, $error );
}

sub an_instalment_payment {
    return Registry::DAO::Payment->create( $tdb, {
        user_id          => $parent->id,
        amount_cents     => 30000,
        status           => 'pending',
        instalment_seq   => 1,
        instalment_count => 3,
        metadata         => { tenant_slug => $slug, enrollment_items => [] },
    } );
}

subtest 'an instalment intent settles inside a running IOLoop' => sub {
    my $payment = an_instalment_payment();
    ok $payment->is_instalment, 'the fixture is an instalment, which is the gate';

    my @customer_calls;
    my %intent_params;

    no warnings 'redefine';
    # Only the ASYNC methods are stubbed. Stubbing the blocking create_customer
    # would remove the very call under test; _await has to run for real.
    local *Registry::Service::Stripe::create_customer_async = sub ( $self, $params ) {
        push @customer_calls, $params;
        return deferred( { id => 'cus_test_284' } );
    };
    local *Registry::Service::Stripe::create_payment_intent_async = sub ( $self, $params ) {
        %intent_params = %$params;
        return deferred( {
            id             => 'pi_test_284',
            client_secret  => 'pi_test_284_secret',
            status         => 'requires_payment_method',
            amount         => $params->{amount},
        } );
    };

    my ( $resolved, $error ) =
      in_running_loop( sub { $payment->create_payment_intent_async($tdb) } );

    is $error, undef, 'no blocking Stripe call was made in the running loop'
        or diag "rejected with: $error";
    ok $resolved, 'the intent is returned';

    # The point of the customer: instalments two and three bill a saved card.
    is $intent_params{customer}, 'cus_test_284',
        'the intent carries the Stripe customer';
    is $intent_params{setup_future_usage}, 'off_session',
        'and asks to keep the card, on-session where a challenge can be met';
    is scalar @customer_calls, 1, 'the customer was created once';
};

subtest 'a one-off charge needs no customer and makes no extra call' => sub {
    my $payment = Registry::DAO::Payment->create( $tdb, {
        user_id      => $parent->id,
        amount_cents => 10000,
        status       => 'pending',
        metadata     => { tenant_slug => $slug, enrollment_items => [] },
    } );
    ok !$payment->is_instalment, 'not an instalment';

    my @customer_calls;
    my %intent_params;

    no warnings 'redefine';
    local *Registry::Service::Stripe::create_customer_async = sub ( $self, $params ) {
        push @customer_calls, $params;
        return deferred( { id => 'cus_should_not_happen' } );
    };
    local *Registry::Service::Stripe::create_payment_intent_async = sub ( $self, $params ) {
        %intent_params = %$params;
        return deferred( {
            id => 'pi_oneoff', client_secret => 'pi_oneoff_secret',
            status => 'requires_payment_method', amount => $params->{amount} } );
    };

    my ( $resolved, $error ) =
      in_running_loop( sub { $payment->create_payment_intent_async($tdb) } );

    is $error, undef, 'settles in the loop';
    ok $resolved, 'the intent is returned';
    is scalar @customer_calls, 0,
        'no customer is created for a charge that does not need one';
    ok !exists $intent_params{customer}, 'and none is sent to Stripe';
};

subtest 'the customer is reused on a second intent for the same payment' => sub {
    # _stripe_customer_for remembers the id on the payment's metadata so a retry
    # does not mint a second customer for the same payer.
    my $payment = an_instalment_payment();

    my @customer_calls;
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_customer_async = sub ( $self, $params ) {
        push @customer_calls, $params;
        return deferred( { id => 'cus_reused_284' } );
    };
    local *Registry::Service::Stripe::create_payment_intent_async = sub ( $self, $params ) {
        return deferred( {
            id => 'pi_reuse_' . scalar(@customer_calls),
            client_secret => 'secret', status => 'requires_payment_method',
            amount => $params->{amount} } );
    };

    my ( undef, $first_error ) =
      in_running_loop( sub { $payment->create_payment_intent_async($tdb) } );
    is $first_error, undef, 'first intent settles';

    my $reloaded = Registry::DAO::Payment->find( $tdb, { id => $payment->id } );
    my ( undef, $second_error ) =
      in_running_loop( sub { $reloaded->create_payment_intent_async($tdb) } );
    is $second_error, undef, 'second intent settles';

    is scalar @customer_calls, 1,
        'the stored customer is reused rather than a second one created';
};

subtest 'instalment customer is created on the seller account' => sub {
    my $payment = Registry::DAO::Payment->create( $tdb, {
        user_id          => $parent->id,
        amount_cents     => 30000,
        status           => 'pending',
        instalment_seq   => 1,
        instalment_count => 3,
        metadata         => { tenant_slug => $slug, enrollment_items => [] },
    } );

    my @accounts;
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_customer = sub ( $self, $params ) {
        push @accounts, $self->stripe_account;
        return { id => 'cus_sync_seller' };
    };
    local *Registry::Service::Stripe::create_customer_async = sub ( $self, $params ) {
        push @accounts, $self->stripe_account;
        return deferred( { id => 'cus_async_seller' } );
    };

    # Sync path, then a second payment through the async path.
    $payment->_stripe_customer_for($tdb);
    is $accounts[0], 'acct_instal_seller', 'sync: the customer is created on the seller account';

    my $async_payment = Registry::DAO::Payment->create( $tdb, {
        user_id          => $parent->id,
        amount_cents     => 30000,
        status           => 'pending',
        instalment_seq   => 1,
        instalment_count => 3,
        metadata         => { tenant_slug => $slug, enrollment_items => [] },
    } );
    my ( undef, $error ) =
      in_running_loop( sub { $async_payment->_stripe_customer_async($tdb) } );
    is $error, undef, 'async customer settles';
    is $accounts[1], 'acct_instal_seller', 'async: the customer is created on the seller account';
};

subtest 'customer from tenant a is never reused on tenant b' => sub {
    # The same family buys from a second studio, on that studio's own account.
    my $slug_b = 'instal_async_b';
    Test::Registry::Fixtures::create_tenant( $db, { name => 'Second Studio', slug => $slug_b } );
    $db->query( 'UPDATE registry.tenants SET stripe_connect_account_id = ? WHERE slug = ?',
        'acct_instal_b', $slug_b );
    give_tenant_terms( $db, $slug_b, { rate => 0 } );
    $db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)', $slug_b, $parent->id );
    my $tdb_b = $dao->connect_schema($slug_b)->db;

    my %customers;    # account => [ customer ids created there ]
    my %intents;      # account => customer sent on the intent
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_customer = sub ( $self, $params ) {
        my $id = 'cus_on_' . $self->stripe_account;
        push @{ $customers{ $self->stripe_account } }, $id;
        return { id => $id };
    };
    local *Registry::Service::Stripe::create_payment_intent = sub ( $self, $params ) {
        $intents{ $self->stripe_account } = $params->{customer};
        return { id => 'pi_' . $self->stripe_account, client_secret => 'secret' };
    };

    for ( [ $tdb, $slug ], [ $tdb_b, $slug_b ] ) {
        my ( $sdb, $s ) = @$_;
        Registry::DAO::Payment->create( $sdb, {
            user_id => $parent->id, amount_cents => 30000, status => 'pending',
            instalment_seq => 1, instalment_count => 3,
            metadata => { tenant_slug => $s, enrollment_items => [] },
        } )->create_payment_intent($sdb);
    }

    is_deeply \%customers,
        { acct_instal_seller => ['cus_on_acct_instal_seller'],
          acct_instal_b      => ['cus_on_acct_instal_b'] },
        'one customer on each account';
    is $intents{acct_instal_b}, 'cus_on_acct_instal_b',
        "B's intent carries B's own customer";
    isnt $intents{acct_instal_b}, 'cus_on_acct_instal_seller',
        "A's customer id is never sent on B's intent";
};

done_testing;
