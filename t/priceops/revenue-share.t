#!/usr/bin/env perl
# ABOUTME: Tests for Registry::PriceOps::RevenueShare — tenant-to-fraction resolver over the tenant's platform entitlement.
# ABOUTME: Covers the held rate, refusal with no entitlement, search_path isolation, and die cases.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Offers qw( offer_terms );
use Test::Registry::PricingProbe qw(with_tenant_plan without_rate_check solo_linked_tenant);
use Registry::PriceOps::RevenueShare qw(revenue_share_fraction_for_tenant platform_offered_fraction);
use Registry::PriceOps::PlatformTerms qw( rate_fraction );
use Registry::DAO::Offer;
use Registry::DAO::Entitlement;
use Registry::DAO::Tenant;
use Registry::DAO::Resource;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( import_all_workflows join_tenant publish_offer );

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;     # Registry::DAO
my $db      = $dao->db;         # Mojo::Pg::Database

# A tenant holding Solo v1. The seed holds none: its only tenant is the
# platform, which takes no share of itself.
my $seeded_slug = solo_linked_tenant($db);

ok $seeded_slug, "made a tenant holding Solo (slug=$seeded_slug)";

# The rate of the plan this tenant's entitlement accepted. The subtests below
# are about mechanisms -- DAO coercion, search_path isolation -- and pinning
# them to a literal made them fail on a rate change for reasons that have
# nothing to do with what they test.
my $seeded_rate = $db->query(q{
    SELECT p.fraction
      FROM registry.entitlements e
      JOIN registry.tenants t ON t.id = e.holder_tenant_id
      JOIN registry.offer_version_payment_plans p
        ON p.offer_version_id = e.offer_version_id AND p.id = e.payment_plan_id
     WHERE t.slug = ?
}, $seeded_slug)->array->[0];

# Against the entitlement's own plan row, not a literal. A test that hardcodes
# the rate fails the day the rate moves, and the obvious repair is to edit the
# number -- which is exactly the drift that let three rates be live at once.
subtest 'a Solo holder is charged its entitlement rate' => sub {
    my $fraction = revenue_share_fraction_for_tenant($db, $seeded_slug);
    ok defined $fraction, 'got a defined fraction';
    cmp_ok abs($fraction - $seeded_rate), '<', 1e-9,
        "the resolver returns what the accepted plan carries (got $fraction)";
};

# The launch rate is a decision, and a decision belongs in one named place.
# revenue_share_fraction_for_tenant answers "what is THIS tenant charged";
# platform_offered_fraction answers "what does the platform sell", which is what
# the marketing copy quotes.
subtest 'the launch rate has one named source' => sub {
    # Only one assertion here, deliberately. platform_offered_fraction dies on
    # zero current published platform offers, on more than one, and on a rate
    # that is undefined, non-numeric or outside [0,1] -- so `defined $launch`
    # and a count of offers both restate its die conditions, and any state that would fail them
    # kills the subtest before they run. A zero rate is inside the accepted
    # range, so this is the one thing the function can return that is wrong.
    my $launch = Registry::PriceOps::RevenueShare::platform_offered_fraction($db);
    cmp_ok $launch, '>', 0,
        'the launch rate is not the Free-plan zero';
};

# The whole point of naming it: displayed and charged cannot drift apart.
subtest 'a tenant holding Solo is charged the launch rate' => sub {
    my $launch  = Registry::PriceOps::RevenueShare::platform_offered_fraction($db);
    my $charged = revenue_share_fraction_for_tenant($db, $seeded_slug);
    cmp_ok abs($charged - $launch), '<', 1e-9,
        'what a Solo holder is charged is what the platform advertises';
};

subtest 'Registry::DAO coercion - accepts DAO object as well as raw db handle' => sub {
    my $fraction = revenue_share_fraction_for_tenant($dao, $seeded_slug);
    cmp_ok abs($fraction - $seeded_rate), '<', 1e-9,
        "coercion works: DAO->db transparently";
};

subtest 'a tenant with no platform entitlement dies, with no Free fallback' => sub {
    $db->query(q{INSERT INTO registry.tenants (name, slug) VALUES ('No Terms', 'rs_no_terms')});

    my $fraction = eval { revenue_share_fraction_for_tenant($db, 'rs_no_terms') };
    ok !defined $fraction, 'no fraction: not the Free plan 0';
    like $@, qr/'rs_no_terms' holds no platform entitlement/, 'dies naming the tenant';
    ok !defined eval { revenue_share_fraction_for_tenant($db, 'rs_no_such_tenant') },
        'nor for a tenant row that is absent';
};

subtest 'search_path isolation - resolver works when search_path excludes registry' => sub {
    # Set search_path to public only (NOT registry) to prove all queries are
    # fully qualified and do not depend on the connection's search_path.
    $db->query("SET search_path TO public");
    my $fraction;
    eval { $fraction = revenue_share_fraction_for_tenant($db, $seeded_slug) };
    ok !$@, "no error when search_path = public: $@";
    cmp_ok abs($fraction - $seeded_rate), '<', 1e-9,
        "correct fraction even with search_path=public";
    # Restore search_path
    $db->query("SET search_path TO registry, public");
};

subtest 'a held plan with no rate dies rather than reading the price' => sub {
    # A payment-processing version whose accepted plan is one_time carries a
    # price and no fraction. Reading the price as a rate would yield a 20000%
    # application fee that Stripe rejects outright.
    my $processing = $db->query(q{SELECT id FROM registry.resources WHERE name = 'payment processing'})
        ->hash->{id};
    my $version = Registry::DAO::Offer->create( $db, { name => 'Flat processing' } )
        ->draft( $db, offer_terms( $processing, price_cents => 20000 ) )->publish($db);
    # Retired at once, so signup still finds exactly one offer to tenants.
    $db->query( 'UPDATE registry.offer_versions SET superseded_at = now() WHERE id = ?', $version->id );
    my $tenant = $db->query(q{INSERT INTO registry.tenants (name, slug) VALUES ('Flat', 'rs_flat')
                              RETURNING id})->hash->{id};
    Registry::DAO::Entitlement->create( $db, {
        holder_tenant_id => $tenant, offer_version_id => $version->id,
        payment_plan_id  => 'pay', starts_at => 'now' } );

    my $fraction = eval { revenue_share_fraction_for_tenant($db, 'rs_flat') };
    ok !defined $fraction, 'no fraction returned for a plan with no rate'
        or diag "returned $fraction -- the price was read as a rate";
    like $@, qr/undefined/i, 'dies naming the missing rate';
};

subtest 'a rate outside 0..1 dies rather than reaching Stripe' => sub {
    # Backstop at the coercion boundary: "2" almost certainly means 2%, but as a
    # fraction it is a 200% fee. No legitimate revenue share sits outside [0,1],
    # so refuse it here rather than let Stripe reject the charge at capture time.
    # The database refuses such a rate too; the guard stays as the resolver's
    # own rule.
    for my $bad ( 2, -0.01 ) {
        without_rate_check( $db, sub { with_tenant_plan( $db, $seeded_slug,
            { rate => $bad },
            sub {
                my $fraction = eval { revenue_share_fraction_for_tenant($db, $seeded_slug) };
                ok !defined $fraction, "rate $bad is refused";
                like $@, qr/between 0 and 1|fraction/i,
                    "rate $bad dies with a message naming the expected range";
            }
        ) } );
    }
};

subtest 'malformed/non-numeric rate dies' => sub {
    # A payment plan's fraction is numeric in the database; the pricing plans
    # the signup page still quotes hold theirs in jsonb, where it can be any
    # string. The one rule refuses it rather than treating it as zero.
    ok !defined eval { rate_fraction( 'abc', 'a test plan' ) }, 'a non-numeric rate is refused';
    like $@, qr/not numeric/i, 'dies saying the value is not numeric';
    ok !defined eval { rate_fraction( "0.\x{0665}", 'a test plan' ) }, 'a non-ASCII digit is not a digit';
    like $@, qr/not numeric/i, 'and is refused as not numeric';
};

subtest 'rate rule is exact decimal arithmetic' => sub {
    # Digits past the fourth place, or past 1, that a float rounds away.
    for my $case (
        [ '0.10000000000000000001' => qr/more than 4 decimal places/ ],
        [ '1.00000000000000000001' => qr/between 0 and 1/ ],
        [ '-0.00000000000000000001' => qr/between 0 and 1/ ],
    ) {
        my ( $raw, $why ) = @$case;
        ok !defined eval { rate_fraction( $raw, 'a test plan' ) }, "$raw is refused";
        like $@, $why, 'naming the rule it breaks';
    }
    is rate_fraction( $_->[0], 'a test plan' ), $_->[1], "$_->[0] reads as $_->[1]" for
        [ '0.0200' => '0.02' ], [ '0.025' => '0.025' ], [ '1.0000' => '1' ], [ '0' => '0' ], [ '0.0000' => '0' ],
        [ '.5' => '0.5' ], [ '+0.0125' => '0.0125' ], [ '1.' => '1' ], [ '25e-3' => '0.025' ], [ '0.0001' => '0.0001' ];
};

subtest 'tenant offer does not change the quoted rate' => sub {
    Registry::DAO::Tenant->provision( $db, { name => 'RS Glaze', slug => 'rs_glaze', users => [] } );
    my $glaze    = $dao->connect_schema('rs_glaze')->db;
    my $resource = Registry::DAO::Resource->create( $glaze, { name => 'payment processing', kind => 'unbounded' } );
    Registry::DAO::Offer->create( $glaze, { name => 'Glaze Membership' } )->draft( $glaze, offer_terms( $resource->id,
        price_cents   => 0,
        payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => 0.01 } ],
    ) )->publish($glaze);

    is platform_offered_fraction($db), '0.025', "a studio's 1% offer leaves the platform quoting Solo's 2.5%";
};

# Solo v2 through offer-publishing, as the platform admin publishes it.
import_all_workflows($dao);
my $platform_admin = Test::Registry::Fixtures::create_user( $dao,
    { username => 'rs_admin', name => 'RS Admin', email => 'admin@rs.test', user_type => 'admin' } );
join_tenant( $dao, $platform_admin, 'admin', 'registry' );

subtest 'solo v2 leaves a v1 holders rate' => sub {
    publish_offer( $dao, 'registry', $platform_admin, {
        'offer-basics'                => { resource_id => '00000000-0000-0000-0001-000000000001',
                                           offer_id    => '00000000-0000-0000-0002-000000000001' },
        'offer-price'                 => { price_cents => 0, currency => 'usd',
                                           units_per_acceptance => 1, per_booking_cap => 1 },
        'one-time-payment'            => { one_time => 'declined' },
        'percentage-of-sales-payment' => { percentage_of_sales => 'offered', rate_percent => '2.4' },
        refund                        => 'keep_fee_with_admin_exception',
    } );

    is platform_offered_fraction($db), '0.024', 'the platform now quotes Solo v2\'s 2.4%';
    is revenue_share_fraction_for_tenant( $db, $seeded_slug ), '0.025',
        'a tenant holding Solo v1 is still charged v1\'s 2.5%';
};

# Last: it leaves registry with no platform offer, which the database refuses
# outside replica mode.
subtest 'offered rate read refuses without exactly one offer' => sub {
    my $processing = $db->query(q{SELECT id FROM registry.resources WHERE name = 'payment processing'})
        ->hash->{id};
    Registry::DAO::Offer->create( $db, { name => 'Rival' } )->draft( $db, offer_terms( $processing,
        price_cents   => 0,
        payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => 0.03 } ],
    ) )->publish($db);

    my $fraction = eval { platform_offered_fraction($db) };
    ok !defined $fraction, 'no rate with two offers: not 0, not 2.5%, not either offer\'s';
    like $@, qr/2 current published offers.*offer-publishing/s, 'refuses naming offer-publishing';

    $db->query('SET session_replication_role = replica');
    $db->query('UPDATE registry.offer_versions SET superseded_at = now() WHERE superseded_at IS NULL');
    $db->query('SET session_replication_role = DEFAULT');

    $fraction = eval { platform_offered_fraction($db) };
    ok !defined $fraction, 'no rate with no offer: not 0, not 2.5%';
    like $@, qr/no current published offer.*offer-publishing/s, 'refuses naming offer-publishing';
};

done_testing;
