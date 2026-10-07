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
        metadata         => { enrollment_items => [] },
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
        metadata     => { enrollment_items => [] },
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

done_testing;
