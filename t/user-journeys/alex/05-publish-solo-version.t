#!/usr/bin/env perl
# ABOUTME: Alex (platform owner) journey: a later Solo version supersedes the current one; offer-publishing over HTTP cannot version Solo's set.
# ABOUTME: Earlier holders keep 0.025, signup lists only the new version, and non-admins of registry are refused at offer-publishing.
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
use Registry::DAO::OfferVersion;
use Registry::PriceOps::PlatformTerms ();
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
my $SOLO_V2            = '9bc4069a-f0a7-0026-3a84-aeb0d0732995';    # solo-grants-workflow-set's

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
    is_deeply [ map { $_->{id} } solo_current()->@* ], [$SOLO_V2], 'Solo starts at its workflow-set version';

    # Solo's current version buys a set (payment processing and the workflow
    # run rights); offer-basics versions an offer only to sell the one
    # resource it already sells, so offer-publishing does not offer Solo.
    my $t = client($alex);
    $t->get_ok('/offer-publishing')->status_is(200);
    submit_step( $t, 'resource', resource_mode => 'existing' );
    ok !$t->tx->res->dom->at(qq{#workflow-content input[name="offer_id"][value="$SOLO"]}),
        'offer-basics does not offer a new version of Solo, whose version buys a set';

    # A later Solo version lists its set, as solo-grants-workflow-set did.
    my $v2  = Registry::DAO::OfferVersion->find( $db, { id => $SOLO_V2 } );
    my $set = $db->query( 'SELECT array_agg(resource_id) FROM registry.offer_version_resources WHERE offer_version_id = ?',
        $SOLO_V2 )->array->[0];
    Registry::DAO::OfferVersion->draft( $db, $SOLO, {
        resource_ids  => $set,
        ( map { $_ => $v2->$_ } qw( price_cents units_per_acceptance per_booking_cap policies ) ),
        payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => 0.024 } ],
    } )->publish($db);

    my $current = solo_current();
    is scalar @$current, 1, 'Solo has exactly one current version';
    is $current->[0]{version}, 3, 'the new one, version 3';
    cmp_ok $current->[0]{fraction}, '==', 0.024, 'at 2.4%';
    ok defined $db->query( 'SELECT superseded_at FROM registry.offer_versions WHERE id = ?', $SOLO_V2 )
        ->hash->{superseded_at}, 'the workflow-set version is superseded';
};

subtest 'signup resolves one platform offer after alex publishes' => sub {
    my ($current) = solo_current()->@*;
    is_deeply [ map { $_->{id} } Registry::PriceOps::PlatformTerms::platform_offers_to_tenants($db)->@* ],
        [ $current->{id} ], 'signup lists exactly one platform offer to tenants: the new Solo version';
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
