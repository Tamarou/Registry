#!/usr/bin/env perl
# ABOUTME: Alex (platform owner) journey: a registry admin publishes a later Solo version through offer-publishing over HTTP.
# ABOUTME: The bootstrap version is superseded, its holders keep 0.025, and non-admins of registry are refused.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( authenticate_as import_all_workflows join_tenant );
use Test::Registry::PricingProbe qw( solo_linked_tenant );
use Registry;
use Registry::DAO;
use Registry::DAO::Payment;
use Registry::DAO::WorkflowSteps::TenantPayment;
use Registry::PriceOps::RevenueShare qw( revenue_share_fraction_for_tenant );

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

# Bootstrap ids (sql/deploy/bootstrap-platform-offers.sql).
my $PAYMENT_PROCESSING = '00000000-0000-0000-0001-000000000001';
my $SOLO               = '00000000-0000-0000-0002-000000000001';
my $SOLO_V1            = '00000000-0000-0000-0003-000000000001';

my $alex = Test::Registry::Fixtures::create_user( $dao,
    { username => 'alex', name => 'Alex', email => 'alex@registry.test', user_type => 'admin' } );
join_tenant( $dao, $alex, 'admin' );
my $staff = Test::Registry::Fixtures::create_user( $dao,
    { username => 'registry_staff', name => 'Registry Staff', email => 'staff@registry.test', user_type => 'staff' } );
join_tenant( $dao, $staff, 'staff' );
Test::Registry::Fixtures::create_tenant( $dao, { name => 'Clay Studio', slug => 'clay_studio' } );
my $other_admin = Test::Registry::Fixtures::create_user( $dao,
    { username => 'clay_admin', name => 'Clay Admin', email => 'admin@clay.test', user_type => 'admin' } );
join_tenant( $dao, $other_admin, 'admin', 'clay_studio' );

# A tenant whose platform entitlement names the bootstrap Solo version.
my $holder = solo_linked_tenant($db);

sub client ( $user = undef ) {
    my $t = Test::Registry::Mojo->new('Registry');
    authenticate_as( $t, $user ) if $user;
    return $t;
}

# Solo's current versions, with the rate of their percentage-of-sales plan.
sub solo_current () {
    return $db->query( q{
        SELECT v.id, v.version, p.fraction FROM registry.offer_versions v
          JOIN registry.offer_version_payment_plans p ON p.offer_version_id = v.id
         WHERE v.offer_id = ? AND v.published_at IS NOT NULL AND v.superseded_at IS NULL
    }, $SOLO )->hashes->to_array;
}

# Submits the page's form with %fields, each of which the form must offer,
# and follows the redirect to the next screen. Returns its URL.
sub submit_step ( $t, $screen, %fields ) {
    my $form = $t->tx->res->dom->at('#workflow-content form');
    ok $form, "$screen has a form" or return;
    ok $form->at(qq{[name="$_"]}), "$screen asks for $_" for sort keys %fields;
    $t->post_ok( $form->attr('action') => form => \%fields )->status_is(302);
    my $next = $t->tx->res->headers->location;
    $t->get_ok($next)->status_is(200);
    return $next;
}

sub refused_at_route ( $user, $who ) {
    my $before = solo_current();
    my $t      = client($user);
    $t->get_ok('/offer-publishing')->status_is( 403, "$who is refused at /offer-publishing on the registry host" );
    $t->post_ok( '/offer-publishing' => form => {} )->status_is( 403, 'and so is a POST' );
    is_deeply solo_current(), $before, "Solo's current version is unchanged";
}

subtest 'registry staff refused solo publishing' => sub {
    refused_at_route( $staff, 'a staff member of registry' );
};

subtest 'other tenant admin refused on the registry host' => sub {
    refused_at_route( $other_admin, 'an admin of another tenant' );
};

subtest 'alex publishes a later solo version' => sub {
    is_deeply [ map { $_->{id} } solo_current()->@* ], [$SOLO_V1], 'Solo starts at its bootstrap version';

    my $t = client($alex);
    $t->get_ok('/offer-publishing')->status_is(200);
    submit_step( $t, 'resource', resource_mode => 'existing' );
    my $offer = $t->tx->res->dom->at(qq{#workflow-content input[name="offer_id"][value="$SOLO"]});
    ok $offer, 'offer-basics offers a new version of Solo';
    like submit_step( $t, 'offer-basics', resource_id => $PAYMENT_PROCESSING, offer_id => $SOLO ),
        qr{/offer-price\z}, 'on to the price';
    is $t->tx->res->dom->at('input[name="price_cents"]')->attr('value'), '0', "the price is pre-filled with Solo's 0";
    submit_step( $t, 'offer-price', price_cents => 0, currency => 'USD', units_per_acceptance => 1, per_booking_cap => 1 );
    submit_step( $t, 'one-time-payment', one_time => 'declined' );
    submit_step( $t, 'percentage-of-sales-payment', percentage_of_sales => 'offered', rate_percent => '2.4' );
    submit_step( $t, 'refund-policy', refund => 'keep_fee_with_admin_exception' );
    submit_step( $t, 'change-policy', change => 'none' );
    submit_step( $t, 'use-policy', use => 'none' );
    submit_step( $t, 'expiry-policy', expiry => 'never' );
    like submit_step( $t, 'publish', action => 'publish' ), qr{/complete\z}, 'publishing lands on the complete page';

    my $current = solo_current();
    is scalar @$current, 1, 'Solo has exactly one current version';
    is $current->[0]{version}, 2, 'the new one, version 2';
    is $current->[0]{fraction}, '0.0240', 'at 2.4%';
    ok defined $db->query( 'SELECT superseded_at FROM registry.offer_versions WHERE id = ?', $SOLO_V1 )
        ->hash->{superseded_at}, 'the bootstrap version is superseded';
};

subtest 'signup resolves one platform offer after alex publishes' => sub {
    my ($current) = solo_current()->@*;
    my $signup = Registry::DAO::WorkflowSteps::TenantPayment->new(
        id => $current->{id}, slug => 'payment', workflow_id => $current->{id}, description => '',
        class => 'Registry::DAO::WorkflowSteps::TenantPayment' );
    is $signup->_platform_offer_to_tenants($db)->{offer_version_id}, $current->{id},
        'signup finds exactly one platform offer to tenants: the new Solo version';
};

subtest 'bootstrap solo holder keeps its rate' => sub {
    is revenue_share_fraction_for_tenant( $db, $holder ), '0.025',
        'a tenant holding the bootstrap version still resolves 0.025';
};

subtest 'payment still stamps the bootstrap solo version' => sub {
    $db->query( q{UPDATE registry.tenants SET stripe_connect_account_id = 'acct_solo_holder' WHERE slug = ?},
        $holder );
    my $parent = Test::Registry::Fixtures::create_user( $db,
        { username => 'holder_parent', name => 'Holder Parent', email => 'parent@holder.test', user_type => 'parent' } );
    my $payment = Registry::DAO::Payment->create( $db, {
        user_id => $parent->id, amount_cents => 10000,
        metadata => { tenant_slug => $holder, enrollment_items => [] } } );
    is $payment->metadata->{platform_offer_version_id}, $SOLO_V1, 'the quote names the bootstrap version';
    is $payment->metadata->{revenue_share_fraction}, '0.025', 'at its 0.025 rate';

    $payment->record_platform_fee( $db, { application_fee_amount => 250 } );
    is $db->query( 'SELECT platform_offer_version_id FROM registry.payments WHERE id = ?', $payment->id )
        ->hash->{platform_offer_version_id}, $SOLO_V1, 'and the charge stamps the bootstrap version';
};

done_testing;
