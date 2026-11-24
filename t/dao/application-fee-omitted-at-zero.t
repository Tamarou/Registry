# ABOUTME: A charge whose platform fee computes to 0 cents sends no application_fee_amount to Stripe.
# ABOUTME: Stripe's rule is that the fee is omitted, never sent as 0; a nonzero fee is still sent.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::PricingProbe qw( give_tenant_terms );
use Registry::DAO::Payment;
use Registry::DAO::User;
use Registry::Service::Stripe;

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;

my $parent = Registry::DAO::User->create( $db, {
    username => 'fee_zero_parent', name => 'Fee Zero Parent',
    user_type => 'parent', email => 'fee_zero@test.local' } );

# A connect-ready tenant holding platform terms at the given rate.
sub tenant_on ( $slug, $rate ) {
    Test::Registry::Fixtures::create_tenant( $db, { name => $slug, slug => $slug } );
    $db->query( q{UPDATE registry.tenants
                     SET stripe_connect_account_id = ?, stripe_charges_enabled = TRUE,
                         stripe_details_submitted = TRUE
                   WHERE slug = ?}, "acct_$slug", $slug );
    give_tenant_terms( $db, $slug, { rate => $rate } );
    return $slug;
}

# The params create_payment_intent hands to the Stripe client.
sub params_for ( $slug, $amount_cents ) {
    my $payment = Registry::DAO::Payment->create( $db, {
        user_id => $parent->id, amount_cents => $amount_cents,
        metadata => { tenant_slug => $slug, enrollment_items => [] } } );
    my $captured;
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_payment_intent = sub ( $self, $params ) {
        $captured = $params;
        return { id => 'pi_fee_zero', client_secret => 'cs_fee_zero' };
    };
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';
    $payment->create_payment_intent( $db, { description => 'fee omission' } );
    return $captured;
}

my $free = tenant_on( 'fee_zero_free', 0 );          # explicit 0%
my $solo = tenant_on( 'fee_zero_solo', '0.025' );    # 2.5%

subtest 'zero fee omits application fee amount while nonzero fee is sent' => sub {
    my $zero = params_for( $free, 10000 );
    ok !exists $zero->{application_fee_amount},
        'a 0% plan charge sends no application_fee_amount key';

    my $paid = params_for( $solo, 10000 );
    is $paid->{application_fee_amount}, 250,
        'a 2.5% charge on $100.00 still carries its 250 cent fee';
};

subtest 'fee rounding to zero cents is omitted' => sub {
    # 2.5% of 19 cents is 0.475 cents, which rounds to 0.
    is Registry::DAO::Payment::application_fee_cents( 19, 0.025 ), 0,
        '19 cents at 2.5% computes a 0 cent fee';
    my $params = params_for( $solo, 19 );
    ok !exists $params->{application_fee_amount},
        'so the 2.5% charge sends no application_fee_amount key';
};

subtest 'zero fee is never sent as a value' => sub {
    my $params = params_for( $free, 10000 );
    ok !( grep { $_ eq 'application_fee_amount' } keys %$params ),
        'application_fee_amount is not a key at all';
    ok !exists $params->{application_fee_amount},
        'so it is not 0, "0", an empty string or undef';
};

$test_db->cleanup_test_database;
done_testing;
