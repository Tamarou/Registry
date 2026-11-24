#!/usr/bin/env perl
# ABOUTME: A tenant's platform fee comes only from its in-effect platform entitlement: absence is refused, never 0%.
# ABOUTME: The platform resolves to exactly 0 through its self-offer, and a Solo holder is charged Solo's stamped rate.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Async qw( settle );
use Registry::DAO;
use Registry::DAO::Entitlement;
use Registry::DAO::Payment;
use Registry::DAO::User;
use Registry::Service::Stripe;    # loaded before its methods are replaced
use Registry::PriceOps::RevenueShare qw( revenue_share_fraction_for_tenant );
use Mojo::Promise;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_absence_is_not_zero';

my $SOLO_V1 = '00000000-0000-0000-0003-000000000001';

# A tenant with its own schema, a Connect account and a parent who pays.
my $n = 0;
sub connect_ready_tenant ($name) {
    my $slug   = $name . '_' . ++$n;
    my $tenant = Test::Registry::Fixtures::create_tenant( $db, { name => $name, slug => $slug } );
    $db->query( 'UPDATE registry.tenants SET stripe_connect_account_id = ?, stripe_charges_enabled = TRUE,
                        stripe_details_submitted = TRUE WHERE slug = ?', "acct_$slug", $slug );
    my $tdb    = $dao->connect_schema($slug)->db;
    my $parent = Registry::DAO::User->create( $tdb, {
        username => "${slug}_parent", email => "${slug}_parent\@test.local",
        name => 'Paying Parent', user_type => 'parent' } );
    return { slug => $slug, id => $tenant->id, db => $tdb, parent => $parent->id };
}

sub hold_solo_v1 ($tenant) {
    return Registry::DAO::Entitlement->create( $db, {
        holder_tenant_id => $tenant->{id}, offer_version_id => $SOLO_V1,
        payment_plan_id  => 'revenue_share', starts_at => '2020-01-01T00:00:00Z' } );
}

# Charges $tenant 10000 cents, recording every request that reaches Stripe.
# Returns the error when the charge is refused.
sub charge ( $tenant, $requests ) {
    no warnings 'redefine';
    local *Registry::Service::Stripe::_request_async = sub ( $client, $method, $endpoint, $data = {}, @ ) {
        push @$requests, { endpoint => $endpoint, account => $client->stripe_account, %$data };
        return Mojo::Promise->resolve( { id => 'pi_absence_' . @$requests, client_secret => 'cs', status => 'succeeded' } );
    };
    my $payment;
    my $ok = eval {
        $payment = Registry::DAO::Payment->create( $tenant->{db}, {
            user_id  => $tenant->{parent}, amount_cents => 10000,
            metadata => { tenant_slug => $tenant->{slug}, enrollment_items => [] } } );
        $payment->create_payment_intent( $tenant->{db}, { description => 'absence' } );
        1;
    };
    return $ok ? ( undef, $payment ) : ( $@, undef );
}

subtest 'tenant with no platform entitlement refused before stripe' => sub {
    my $tenant = connect_ready_tenant('no_terms');

    ok !eval { revenue_share_fraction_for_tenant( $db, $tenant->{slug} ); 1 }, 'the resolver refuses';
    like $@, qr/\Q'$tenant->{slug}'\E/, 'naming the tenant';
    unlike $@, qr/Free plan/, 'with no fallback to the Free plan';

    my @requests;
    my ($err) = charge( $tenant, \@requests );
    like $err, qr/\Q'$tenant->{slug}'\E holds no platform entitlement/, 'the charge is refused naming the tenant';
    is scalar @requests, 0, 'and no request reached Stripe';
};

subtest 'platform tenant resolves to zero' => sub {
    is revenue_share_fraction_for_tenant( $db, 'registry' ), 0, 'the platform takes exactly 0 of its own sales';
    is revenue_share_fraction_for_tenant( $dao->connect_schema('registry')->db, 'registry' ), 0,
        'on any connection';
};

subtest 'solo holder charged its stamped rate' => sub {
    my $tenant = connect_ready_tenant('solo_holder');
    hold_solo_v1($tenant);

    is revenue_share_fraction_for_tenant( $db, $tenant->{slug} ), '0.025', 'the resolver answers Solo v1 rate';

    my @requests;
    my ( $err, $payment ) = charge( $tenant, \@requests );
    is $err, undef, 'the charge is made';
    is $payment->metadata->{revenue_share_fraction}, '0.025', 'the payment carries the exact rate';
    is $payment->metadata->{platform_offer_version_id}, $SOLO_V1, 'and the version it was priced under';
    is $requests[0]{account}, "acct_$tenant->{slug}", 'on the tenant account';
    is $requests[0]{application_fee_amount}, 250, 'taking 2.5% of 10000 cents';

    is $payment->stamped_platform_terms($db)->{refund_policy}{kind}, 'keep_fee_with_admin_exception',
        'the stamped version keeps the fee on a refund';
    @requests = ();
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async = sub ( $client, $params ) {
            push @requests, $params;
            return Mojo::Promise->resolve( { id => 're_absence', status => 'succeeded' } );
        };
        $tenant->{db}->update( 'payments', { status => 'completed', stripe_payment_intent_id => 'pi_absence_paid' },
            { id => $payment->id } );
        settle( Registry::DAO::Payment->find( $tenant->{db}, { id => $payment->id } )->refund_async( $tenant->{db} ) );
    }
    is scalar @requests, 1, 'a refund is sent';
    ok !exists $requests[0]{refund_application_fee}, 'and the platform keeps its fee';
};

done_testing;
