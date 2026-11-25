#!/usr/bin/env perl
# ABOUTME: Signup's review page lists the platform's published offers to tenants, Solo preselected,
# ABOUTME: and carries only a currently published one as the choice; with none published it refuses signup.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is isnt ok like unlike subtest )];
defer { done_testing };

use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO::Tenant;
use Registry::DAO::Offer;
use Registry::DAO::Resource;
use Registry::DAO::WorkflowRun;
use Registry::DAO::Entitlement;

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
my $db   = $dao->db;
$ENV{DB_URL} = $t_db->uri;

$dao->import_workflows(['workflows/tenant-signup.yml']);

# This file walks signup a dozen times from one address.
use Registry::Middleware::RateLimit;
$Registry::Middleware::RateLimit::GENERAL_LIMIT = $Registry::Middleware::RateLimit::AUTH_LIMIT = 10_000;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $dao } );
$dao->current_tenant('registry');

# The bootstrap seed's fixed ids.
my $SOLO               = '00000000-0000-0000-0002-000000000001';
my $SOLO_V1            = '00000000-0000-0000-0003-000000000001';
my $SELF_OFFER         = '00000000-0000-0000-0003-000000000002';
my $PAYMENT_PROCESSING = '00000000-0000-0000-0001-000000000001';

# A rate-only platform offer to tenants: $0 and a percentage of sales.
sub publish_platform_offer ( $name, $fraction ) {
    my $offer = Registry::DAO::Offer->create( $db, { name => $name } );
    return $offer->draft( $db, offer_terms( $PAYMENT_PROCESSING,
        price_cents   => 0,
        payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => $fraction } ],
    ) )->publish($db);
}

sub withdraw ($version) {
    $db->query( 'UPDATE registry.offer_versions SET superseded_at = now() WHERE id = ?', $version->id );
}

sub current_solo () { Registry::DAO::Offer->find( $db, { id => $SOLO } )->current_version($db)->id }

# Walks signup to its review page and returns that page's URL.
my $n = 0;
sub to_review (%extra) {
    $n++;
    $t->post_ok('/tenant-signup')->status_is(302);
    my $url = $t->tx->res->headers->location;
    $t->post_ok( $url => form => { name => "Offer Studio $n", billing_email => "owner$n\@offers.example", %extra } )
      ->status_is(302);
    $url = $t->tx->res->headers->location;
    $t->post_ok( $url => form => {
        admin_name => "Admin $n", admin_email => "admin$n\@offers.example",
        admin_username => "offers_admin_$n", admin_user_type => 'admin', %extra,
    } )->status_is(302);
    my $review = $t->tx->res->headers->location;
    $t->get_ok($review)->status_is(200);
    return $review;
}

sub run_of ($url) {
    my ($id) = $url =~ m{/tenant-signup/([0-9a-f-]{36})/};
    return Registry::DAO::WorkflowRun->find( $db, { id => $id } );
}

sub tenant_named ($n) {
    $db->query( 'SELECT id, slug FROM registry.tenants WHERE name = ?', "Offer Studio $n" )->hash;
}

# Posts $choice on the review page and says whether signup refused it with
# nothing carried and no tenant made.
sub refused ( $review, $choice, $label ) {
    $t->post_ok( $review => form => { terms_accepted => 1, defined $choice ? ( offer_version => $choice ) : () } );
    isnt $t->tx->res->code, 500, "$label: no server error";
    ok !tenant_named($n), "$label: no tenant";
    ok !exists run_of($review)->data->{selected_offer_version}, "$label: nothing carried";
    $t->get_ok($review)->status_is(200)
      ->content_like( qr/choose one of the plans/i, "$label: told to choose a listed plan" );
}

sub choices () { $t->tx->res->dom->find('input[name="offer_version"]')->map( attr => 'value' )->to_array }

sub checked () {
    my $el = $t->tx->res->dom->at('input[name="offer_version"][checked]');
    return $el && $el->attr('value');
}

sub page_text () {
    my $dom = $t->tx->res->dom;
    $dom->find('style, script')->each( sub { $_->remove } );
    return $dom->all_text;
}

subtest 'review page lists published offers with solo preselected' => sub {
    to_review();
    is_deeply_list( choices(), [$SOLO_V1], 'Solo v1 is the one choice' );
    is checked(), $SOLO_V1, 'and it is preselected';
    my $text = page_text();
    like $text, qr/Solo/, 'named from the offer';
    like $text, qr/\$0 a month, 2\.5% of each payment you take/, 'with its terms from the version';
};

subtest 'new solo version replaces old and drafts are hidden' => sub {
    my $solo = Registry::DAO::Offer->find( $db, { id => $SOLO } );
    my $v2 = $solo->draft( $db, offer_terms( $PAYMENT_PROCESSING,
        price_cents   => 0,
        payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => 0.03 } ],
    ) )->publish($db);
    my $draft = $solo->draft( $db, offer_terms( $PAYMENT_PROCESSING,
        price_cents   => 0,
        payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => 0.04 } ],
    ) );

    to_review();
    is_deeply_list( choices(), [ $v2->id ], 'v2 is listed, v1 and the draft are not' );
    is checked(), $v2->id, 'v2 is preselected';
    like page_text(), qr/3% of each payment you take/, 'quoting v2';
    unlike page_text(), qr/4%/, 'not the draft';
};

subtest 'solo preselected beside a cheaper offer' => sub {
    my $cheaper = publish_platform_offer( 'Aardvark Plan', 0.01 );
    to_review();
    is_deeply_list( choices(), [ current_solo(), $cheaper->id ], 'both are listed' );
    is checked(), current_solo(), 'Solo is preselected, not the cheaper offer';
    withdraw($cheaper);
};

subtest 'only a published platform offer is carried' => sub {
    my $kiln = publish_platform_offer( 'Kiln Plan', 0.02 );
    my $review = to_review();
    is_deeply_list( choices(), [ current_solo(), $kiln->id ], 'both published offers are listed' );

    $t->post_ok( $review => form => { terms_accepted => 1, offer_version => $kiln->id } )->status_is(302);
    is run_of($review)->data->{selected_offer_version}, $kiln->id, 'the posted version is carried';
    my $tenant = tenant_named($n);
    ok $tenant, 'and signup completed';
    my ($held) = Registry::DAO::Entitlement->find( $db, { holder_tenant_id => $tenant->{id} } );
    is $held && $held->offer_version_id, $kiln->id, 'on the chosen offer';

    # A client cannot write the run key on another step.
    my $other = to_review( selected_offer_version => $kiln->id );
    ok !exists run_of($other)->data->{selected_offer_version}, 'a posted selected_offer_version is stripped';
    withdraw($kiln);
};

subtest 'pages quote the chosen version' => sub {
    my $kiln = publish_platform_offer( 'Kiln Plan Two', 0.02 );
    my $review = to_review();
    my $label = $t->tx->res->dom->at( sprintf 'label[for="offer-%s"]', $kiln->id );
    ok $label, 'the chosen version has its own label';
    like $label && $label->all_text, qr/Kiln Plan Two.*\$0 a month, 2% of each payment you take/s,
        'naming it and quoting its rate';

    $t->post_ok( $review => form => { terms_accepted => 1, offer_version => $kiln->id } )->status_is(302);
    $t->get_ok( $t->tx->res->headers->location )->status_is(200);
    my $text = page_text();
    like $text, qr/Kiln Plan Two/, 'the confirmation names the chosen version';
    like $text, qr/\b2% of what you collect/, 'and quotes its rate';
    unlike $text, qr/\b3%/, 'not Solo\'s';
    withdraw($kiln);
};

subtest 'retired platform plans not listed or accepted' => sub {
    is $db->query( q{SELECT count(*) FROM registry.pricing_plans
                      WHERE metadata->>'created_by_migration' = 'seed-tier-pricing-options'} )
        ->array->[0], 0, 'the seeded Studio and Empire plans are gone';
    # Solo's legacy plan row is the one left, and it is not a published version.
    my $plan = $db->query( q{SELECT id, plan_name FROM registry.pricing_plans
                              WHERE plan_name = 'Solo' AND superseded_at IS NULL} )->hash;
    ok $plan, "Solo's legacy plan row resolved" or return;
    my $review = to_review();
    unlike $t->tx->res->body, qr/\Q$plan->{id}\E/, 'its id is not listed';
    refused( $review, $plan->{id}, 'the legacy plan id' );
};

subtest 'other tenant offer not listed or accepted' => sub {
    Registry::DAO::Tenant->provision( $db, { name => 'Glaze', slug => 'glaze', users => [] } );
    my $glaze = $dao->connect_schema('glaze')->db;
    my $resource = Registry::DAO::Resource->create( $glaze, { name => 'payment processing', kind => 'unbounded' } );
    my $offer = Registry::DAO::Offer->create( $glaze, { name => 'Glaze Membership' } );
    my $version = $offer->draft( $glaze, offer_terms( $resource->id,
        price_cents   => 0,
        payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => 0.01 } ],
    ) )->publish($glaze);

    my $review = to_review();
    unlike page_text(), qr/Glaze Membership/, 'not listed';
    refused( $review, $version->id, 'the studio offer' );
};

subtest 'platform self offer not listed or accepted' => sub {
    my $review = to_review();
    is_deeply_list( choices(), [ current_solo() ], 'only Solo is listed' );
    refused( $review, $SELF_OFFER, 'the self-offer' );
};

subtest 'superseded or draft version refused' => sub {
    my ($draft) = grep { !$_->is_published } Registry::DAO::Offer->find( $db, { id => $SOLO } )->versions($db)->@*;
    ok $draft, 'Solo has a draft';
    my $review = to_review();
    refused( $review, $SOLO_V1,    'superseded Solo v1' );
    refused( $review, $draft->id,  'the Solo draft' );
};

subtest 'malformed choice refused and never defaulted' => sub {
    my $review = to_review();
    refused( $review, undef,                 'absent' );
    refused( $review, '',                    'empty' );
    refused( $review, 'not-a-uuid',          'non-UUID' );
    refused( $review, q{' OR 1=1; --},       'SQL metacharacters' );
};

subtest 'offer description rendered escaped' => sub {
    my $loud = publish_platform_offer( '<script>alert("x")</script><b>Loud</b>', 0.02 );
    to_review();
    my $body = $t->tx->res->body;
    unlike $body, qr/<script>alert/, 'no live script';
    unlike $body, qr/<b>Loud/, 'no live markup';
    like $body, qr/&lt;script&gt;alert/, 'shown escaped';
    withdraw($loud);
};

subtest 'submitted rate or plan name never shown' => sub {
    my %forged = ( plan_name => 'Forged Plan', revenue_share_percent => '0.1', fraction => '0.001',
                   payment_plan_id => 'forged_plan', formatted_price => 'Forged Price' );
    my $review = to_review(%forged);
    my $text = page_text();
    unlike $text, qr/Forged|0\.1%/, 'the review page quotes none of it';

    $t->post_ok( $review => form => { terms_accepted => 1, offer_version => current_solo(), %forged } )
      ->status_is(302);
    $t->get_ok( $t->tx->res->headers->location )->status_is(200);
    $text = page_text();
    unlike $text, qr/Forged|0\.1%/, 'nor does the confirmation';
    like $text, qr/\b3% of what you collect/, 'which quotes the chosen version';
};

# Last: it leaves the platform with nothing on offer.
subtest 'no published offer refuses signup and quotes no rate' => sub {
    # The database refuses this state (platform-offer-to-tenants-guard); lifted
    # in this file's own database so signup's own refusal is still proven.
    $db->query('ALTER TABLE registry.offer_versions DISABLE TRIGGER offer_versions_keep_platform_offer');
    $db->query( q{UPDATE registry.offer_versions SET superseded_at = now()
                   WHERE published_at IS NOT NULL AND superseded_at IS NULL
                     AND NOT conditions @> '[{"kind": "holder_is_offerer"}]'} );

    my $review = to_review();
    my $text = page_text();
    like $text, qr/signup is unavailable/i, 'signup is refused';
    unlike $text, qr/\d\s*%/, 'and no rate is quoted';
    is scalar choices()->@*, 0, 'nothing to choose';
    ok !$t->tx->res->dom->at('#create-studio'), 'and no button to create a studio';

    $t->post_ok( $review => form => { terms_accepted => 1, offer_version => $SOLO_V1 } );
    isnt $t->tx->res->code, 500, 'posting anyway is no server error';
    ok !tenant_named($n), 'and makes no tenant';
    $t->get_ok($review)->status_is(200)->content_like( qr/signup is unavailable/i, 'it says why' );
};

sub is_deeply_list ( $got, $want, $label ) {
    is join( ',', sort @$got ), join( ',', sort @$want ), $label;
}

$t_db->cleanup_test_database;
