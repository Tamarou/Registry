# ABOUTME: The platform fee is fixed when the payment is quoted and the Stripe customer create is keyed.
# ABOUTME: A retry reuses the same Idempotency-Key, so it must send the same fee and make no second customer.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Mojo::Promise;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Payment;
use Registry::DAO::User;
use Registry::Service::Stripe;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_fee_snapshot';

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;

my $parent = Registry::DAO::User->create( $db, {
    username => 'fee_snap_parent', name => 'Fee Snap Parent',
    user_type => 'parent', email => 'fee_snap@test.local' } );

sub plan_id ($name) {
    $db->query( 'SELECT id FROM registry.pricing_plans WHERE plan_name = ? LIMIT 1', $name )
        ->hash->{id};
}

sub move_to_plan ( $slug, $plan_name ) {
    $db->query( 'UPDATE registry.tenants SET platform_pricing_plan_id = ? WHERE slug = ?',
        plan_id($plan_name), $slug );
}

my $slug = 'fee_snap';
Test::Registry::Fixtures::create_tenant( $db, { name => $slug, slug => $slug } );
$db->query( q{UPDATE registry.tenants
                 SET stripe_connect_account_id = 'acct_fee_snap', stripe_charges_enabled = TRUE,
                     stripe_details_submitted = TRUE
               WHERE slug = ?}, $slug );

# Stripe as the wire sees it: every request the service would send, with its
# Idempotency-Key. A keyed request Stripe has seen returns what it first made.
# A reused key with a different body is refused, as Stripe answers
# idempotency_error.
my ( @sent, @made, %made_by_key, %body_by_key, $serial );
sub with_wire ( $code, %fail ) {
    no warnings 'redefine';
    local *Registry::Service::Stripe::_request_async =
      sub ( $self, $method, $endpoint, $data = {}, $ik = undef, @ ) {
        push @sent, { endpoint => $endpoint, data => {%$data}, key => $ik };
        if ( defined $ik ) {
            my $body = join '&', map { "$_=" . ( $data->{$_} // '' ) } sort keys %$data;
            return Mojo::Promise->reject("idempotency_error\n")
                if ( $body_by_key{$ik} //= $body ) ne $body;
        }
        my $obj = ( defined $ik && $made_by_key{$ik} ) || do {
            my $new = { id => "${endpoint}_" . ++$serial, client_secret => 'cs' };
            push @made, [ $endpoint, $new->{id} ];
            $made_by_key{$ik} = $new if defined $ik;
            $new;
        };
        # Stripe made it, but the response never came back.
        return Mojo::Promise->reject("connection reset\n") if delete $fail{$endpoint};
        return Mojo::Promise->resolve($obj);
    };
    $code->();
}

subtest 'a retry after a plan change sends the originally computed fee' => sub {
    move_to_plan( $slug, 'Solo' );    # 2.5%
    my $payment = Registry::DAO::Payment->create( $db, {
        user_id => $parent->id, amount_cents => 10000,
        metadata => { tenant_slug => $slug, enrollment_items => [] } } );

    @sent = ();
    with_wire( sub {
        eval { $payment->create_payment_intent( $db, {} ); 1 };
    }, payment_intents => 1 );

    move_to_plan( $slug, 'Registry Free' );    # 0%: the tenant changed plan

    with_wire( sub {
        Registry::DAO::Payment->find( $db, { id => $payment->id } )
            ->create_payment_intent( $db, {} );
    } );

    is scalar @sent, 2, 'two intent creates went out';
    is $sent[0]{key}, $sent[1]{key}, 'under one Idempotency-Key';
    is $sent[0]{data}{application_fee_amount}, 250, 'the first carried the 2.5% fee';
    is $sent[1]{data}{application_fee_amount}, 250,
        'and the retry carried the same fee, not the new plan\'s';
};

subtest 'a retried customer create uses an idempotency key and makes one customer' => sub {
    my $payment = Registry::DAO::Payment->create( $db, {
        user_id => $parent->id, amount_cents => 3333, status => 'pending',
        instalment_seq => 1, instalment_count => 3,
        metadata => { tenant_slug => $slug, enrollment_items => [] } } );

    @sent = @made = ();
    with_wire( sub {
        eval { $payment->create_payment_intent( $db, {} ); 1 };
    }, customers => 1 );
    with_wire( sub {
        Registry::DAO::Payment->find( $db, { id => $payment->id } )
            ->create_payment_intent( $db, {} );
    } );

    my @creates = grep { $_->{endpoint} eq 'customers' } @sent;
    is scalar @creates, 2, 'the customer create was sent twice';
    ok defined $creates[0]{key}, 'with an Idempotency-Key';
    is $creates[1]{key}, $creates[0]{key}, 'the same key on the retry';
    ok !exists $creates[0]{data}{_idempotency_key}, 'sent as a header, not a form field';

    my @customers = grep { $_->[0] eq 'customers' } @made;
    is scalar @customers, 1, 'so Stripe made one customer';
    is Registry::DAO::Payment->find( $db, { id => $payment->id } )->metadata->{stripe_customer_id},
        $customers[0][1], 'and the payment remembers it';
};

subtest 'a retry after a profile edit ends with one customer stored on the payment' => sub {
    my $payment = Registry::DAO::Payment->create( $db, {
        user_id => $parent->id, amount_cents => 3333, status => 'pending',
        instalment_seq => 1, instalment_count => 3,
        metadata => { tenant_slug => $slug, enrollment_items => [] } } );

    @sent = @made = ();
    with_wire( sub {
        eval { $payment->create_payment_intent( $db, {} ); 1 };
    }, customers => 1 );

    # The parent edits their profile before the retry.
    $db->query( 'UPDATE user_profiles SET email = ?, name = ? WHERE user_id = ?',
        'fee_snap_new@test.local', 'Renamed Parent', $parent->id );

    my $ok = with_wire( sub {
        eval {
            Registry::DAO::Payment->find( $db, { id => $payment->id } )
                ->create_payment_intent( $db, {} );
            1;
        };
    } );
    ok $ok, 'the retry succeeds';

    my @creates = grep { $_->{endpoint} eq 'customers' } @sent;
    is_deeply $creates[1]{data}, $creates[0]{data}, 'with the body the first create sent';

    my @customers = grep { $_->[0] eq 'customers' } @made;
    is scalar @customers, 1, 'so Stripe made one customer';
    is Registry::DAO::Payment->find( $db, { id => $payment->id } )->metadata->{stripe_customer_id},
        $customers[0][1], 'and the payment stores it';
};

$test_db->cleanup_test_database;
done_testing;
