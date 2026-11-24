#!/usr/bin/env perl
# ABOUTME: The bootstrap seeds Solo v1, the platform's offers to itself and registry's entitlements to them.
# ABOUTME: A data change, invisible to the schema revert harness, so it deploys to its parent and back here.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use App::Sqitch;
use Capture::Tiny qw( capture_stderr );
use Test::PostgreSQL;
use Mojo::Pg;

use constant PLATFORM_UUID => '00000000-0000-0000-0000-000000000000';
use constant CHANGE        => 'bootstrap-platform-offers';

my $pgsql  = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri    = $pgsql->uri;
my $sqitch = App::Sqitch->new();

lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', CHANGE . '^' ) }
    'deploy to the parent change succeeds';
lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', CHANGE ) }
    'deploy the bootstrap offers';

my $db = Mojo::Pg->new($uri)->db;

# The platform's current published versions offered to tenants: those not
# restricted to the platform itself by holder_is_offerer.
sub offered_to_tenants () {
    return $db->query( q{
        SELECT v.*, o.name AS offer_name, r.name AS resource_name
          FROM registry.offer_versions v
          JOIN registry.offers o    ON o.id = v.offer_id
          JOIN registry.resources r ON r.id = v.resource_id
         WHERE v.published_at IS NOT NULL AND v.superseded_at IS NULL
           AND NOT v.conditions @> '[{"kind": "holder_is_offerer"}]'
    } )->expand->hashes->to_array;
}

sub plans_of ($version_id) {
    return $db->query( q{
        SELECT id, kind, fraction FROM registry.offer_version_payment_plans
         WHERE offer_version_id = ? ORDER BY id
    }, $version_id )->hashes->to_array;
}

subtest 'bootstrap publishes solo v1 only' => sub {
    my $offered = offered_to_tenants();
    is scalar @$offered, 1, 'the platform offers tenants exactly one current version';
    my $solo = $offered->[0];
    is $solo->{offer_name},    'Solo',               'it is Solo';
    is $solo->{version},       1,                    'version 1';
    is $solo->{resource_name}, 'payment processing', 'it buys payment processing';
    is $solo->{price_cents},   0,                    'at $0';
    is $solo->{policies}{refund}{kind}, 'keep_fee_with_admin_exception',
        'refund policy keeps the fee, with an admin exception';

    my $plans = plans_of( $solo->{id} );
    is scalar @$plans, 1, 'one payment plan';
    is $plans->[0]{kind}, 'percentage_of_sales', 'a percentage of sales';
    cmp_ok $plans->[0]{fraction}, '==', 0.025, 'at 2.5%';
};

# Entitlements in effect now, with what they bought and under which plan.
sub held_now ( $holder = PLATFORM_UUID ) {
    return $db->query( q{
        SELECT e.*, v.price_cents, v.conditions, r.name AS resource_name, r.kind AS resource_kind,
               r.capacity, p.kind AS plan_kind, p.fraction
          FROM registry.entitlements e
          JOIN registry.offer_versions v ON v.id = e.offer_version_id
          JOIN registry.resources r      ON r.id = v.resource_id
          JOIN registry.offer_version_payment_plans p
               ON p.offer_version_id = e.offer_version_id AND p.id = e.payment_plan_id
         WHERE e.holder_tenant_id = ? AND e.in_effect @> now()
         ORDER BY r.name
    }, $holder )->expand->hashes->to_array;
}

sub held_for ($resource) { [ grep { $_->{resource_name} eq $resource } held_now()->@* ] }

subtest 'platform holds its explicit zero percent self offer' => sub {
    my $held = held_for('payment processing');
    is scalar @$held, 1, 'registry holds one payment-processing entitlement';
    is $held->[0]{plan_kind}, 'percentage_of_sales', 'under a percentage-of-sales plan';
    ok defined $held->[0]{fraction} && $held->[0]{fraction} == 0, 'of exactly 0';
};

subtest 'platform holds uncapped email sending' => sub {
    my $held = held_for('email sending');
    is scalar @$held, 1, 'registry holds one email-sending entitlement';
    is $held->[0]{resource_kind}, 'unbounded', 'email sending is unbounded';
    is $held->[0]{capacity}, undef, 'with no capacity';
};

my @PRODUCT_DESIGN = qw( offer-publishing program-creation program-setup session-creation event-creation );

subtest 'platform holds the right to run product design' => sub {
    for my $slug (@PRODUCT_DESIGN) {
        is $db->query( 'SELECT count(*) FROM registry.resources WHERE name = ?', "run:$slug" )
            ->array->[0], 1, "one run resource for $slug";
        my $held = held_for("run:$slug");
        is scalar @$held, 1, "registry holds one in-effect right to run $slug";
    }
    is $db->query( q{
        SELECT count(*) FROM registry.entitlements e
          JOIN registry.offer_versions v ON v.id = e.offer_version_id
          JOIN registry.resources r      ON r.id = v.resource_id
         WHERE r.name LIKE 'run:%' AND e.holder_tenant_id IS DISTINCT FROM ?
    }, PLATFORM_UUID )->array->[0], 0, 'no other tenant holds a run right';
};

subtest 'self offers carry holder is offerer and solo does not' => sub {
    my $solo = $db->query( q{
        SELECT v.conditions FROM registry.offer_versions v
          JOIN registry.offers o ON o.id = v.offer_id
         WHERE o.name = 'Solo' AND v.version = 1
    } )->expand->hash;
    is_deeply $solo->{conditions}, [], 'Solo v1 carries no condition';

    my $held = held_now();
    ok scalar @$held, 'registry holds the platform offers to itself';
    is_deeply $_->{conditions}, [ { kind => 'holder_is_offerer' } ],
        "the self offer for $_->{resource_name} is restricted to the platform"
        for @$held;
};

my @SEEDED = qw( resources offers offer_versions entitlements );

# The ids of every row of @SEEDED, by table.
sub ids_by_table () {
    return { map { $_ => $db->query("SELECT id FROM registry.$_ ORDER BY id")->arrays->flatten->to_array } @SEEDED };
}

subtest 'seed reverts and redeploys by its own rows' => sub {
    is $db->query( q{
        SELECT count(*) FROM registry.offer_versions v
          JOIN registry.pricing_plans pp ON pp.id IN (v.id, v.offer_id, v.resource_id)
    } )->array->[0], 0, 'no offer version reuses a pricing_plans id';
    is $db->query( q{
        SELECT count(*) FROM pg_constraint
         WHERE conrelid = 'registry.offer_versions'::regclass
           AND confrelid = 'registry.pricing_plans'::regclass
    } )->array->[0], 0, 'and none references pricing_plans';

    # A row the seed did not create, which the revert must leave alone.
    my $resource = $db->query( q{INSERT INTO registry.resources (name, kind)
                                 VALUES ('planted', 'unbounded') RETURNING id} )->hash->{id};
    my $offer = $db->query( q{INSERT INTO registry.offers (name) VALUES ('Planted') RETURNING id} )
        ->hash->{id};
    $db->query( q{INSERT INTO registry.offer_versions
                      (offer_id, version, resource_id, price_cents, units_per_acceptance, per_booking_cap)
                  VALUES (?, 1, ?, 0, 1, 1)}, $offer, $resource );

    my $deployed = ids_by_table();
    lives_ok { $sqitch->run( 'sqitch', 'revert', '-t', $uri, '--to', CHANGE . '^', '-y' ) }
        'the seed reverts';
    my $reverted = ids_by_table();
    is_deeply $reverted->{resources}, [$resource], 'only the planted resource is left';
    is_deeply $reverted->{offers},    [$offer],    'only the planted offer is left';
    is scalar $reverted->{offer_versions}->@*, 1, 'only the planted version is left';
    is_deeply $reverted->{entitlements}, [], 'no entitlement is left';

    lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', CHANGE ) } 'the seed redeploys';
    is_deeply ids_by_table(), $deployed, 'redeploying recreates the same rows';
};

my $SOLO_V1 = q{
    SELECT v.* FROM registry.offer_versions v JOIN registry.offers o ON o.id = v.offer_id
     WHERE o.name = 'Solo' AND v.version = 1
};

# The platform's 0% offer to itself: the self offer that buys payment processing.
sub self_offer () {
    return $db->query( q{
        SELECT v.* FROM registry.offer_versions v
          JOIN registry.resources r ON r.id = v.resource_id
         WHERE r.name = 'payment processing'
           AND v.conditions @> '[{"kind": "holder_is_offerer"}]'
    } )->hashes->to_array;
}

subtest 'redeploy leaves one solo offer' => sub {
    lives_ok { $sqitch->run( 'sqitch', 'revert', '-t', $uri, '--to', CHANGE . '^', '-y' ) } 'reverts';
    lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', CHANGE ) } 'redeploys';
    is $db->query(q{SELECT count(*) FROM registry.offers WHERE name = 'Solo'})->array->[0], 1,
        'one Solo offer';
    is $db->query( q{
        SELECT count(*) FROM registry.offer_versions v JOIN registry.offers o ON o.id = v.offer_id
         WHERE o.name = 'Solo' AND v.published_at IS NOT NULL AND v.superseded_at IS NULL
    } )->array->[0], 1, 'one current Solo version';
};

subtest 'self offer not offered to tenants' => sub {
    my $self = self_offer();
    is scalar @$self, 1, 'one 0% self offer';
    ok !grep( { $_->{id} eq $self->[0]{id} } offered_to_tenants()->@* ), 'it is not offered to tenants';
    is $db->query( q{
        SELECT count(*) FROM registry.entitlements
         WHERE offer_version_id = ? AND holder_tenant_id IS DISTINCT FROM ?
    }, $self->[0]{id}, PLATFORM_UUID )->array->[0], 0, 'no tenant but registry holds it';
};

subtest 'self offer zero and solo rate stored exactly' => sub {
    my $fraction = sub ($version_id) {
        $db->query( 'SELECT fraction::text FROM registry.offer_version_payment_plans WHERE offer_version_id = ?',
            $version_id )->array->[0];
    };
    is $fraction->( self_offer()->[0]{id} ), '0', 'the self offer stores exactly 0, not NULL';
    is $fraction->( $db->query($SOLO_V1)->hash->{id} ), '0.025', 'Solo stores exactly 0.025';
};

subtest 'seeded solo v1 is immutable' => sub {
    my $solo = $db->query($SOLO_V1)->hash;
    throws_ok {
        $db->query( 'UPDATE registry.offer_version_payment_plans SET fraction = 0.03 WHERE offer_version_id = ?',
            $solo->{id} )
    } qr/is published: its payment plans cannot be/, 'its percentage cannot be changed';
    throws_ok { $db->query( 'UPDATE registry.offer_versions SET price_cents = 100 WHERE id = ?', $solo->{id} ) }
        qr/immutable once published/, 'nor its price';
    is $db->query( 'SELECT fraction::text FROM registry.offer_version_payment_plans WHERE offer_version_id = ?',
        $solo->{id} )->array->[0], '0.025', 'the rate is unchanged';
};

subtest 'only registry holds seeded entitlements' => sub {
    is $db->query( q{
        SELECT count(*) FROM registry.entitlements WHERE holder_tenant_id IS DISTINCT FROM ?
    }, PLATFORM_UUID )->array->[0], 0, 'no other holder holds any entitlement';
    is scalar held_for('email sending')->@*, 1, 'registry holds email sending';
    is scalar( grep { $_->{resource_name} =~ /\Arun:/ } held_now()->@* ), 5,
        'registry holds the five product-design run rights';
};

subtest 'each self right is its own one time zero offer version' => sub {
    my $rights = $db->query( q{
        SELECT v.id, v.offer_id, v.price_cents, r.name AS resource_name,
               (SELECT count(*) FROM registry.offer_version_payment_plans p
                 WHERE p.offer_version_id = v.id) AS plans,
               (SELECT count(*) FROM registry.offer_version_payment_plans p
                 WHERE p.offer_version_id = v.id AND p.kind = 'one_time') AS one_time_plans
          FROM registry.offer_versions v
          JOIN registry.resources r ON r.id = v.resource_id
         WHERE r.name = 'email sending' OR r.name LIKE 'run:%'
    } )->hashes->to_array;
    is scalar @$rights, 6, 'six self rights: email sending and five run rights';
    my %offers = map { $_->{offer_id} => 1 } @$rights;
    is scalar keys %offers, 6, 'each is its own offer';
    my $self_offer_id = self_offer()->[0]{offer_id};
    ok !$offers{$self_offer_id}, 'none is part of the 0% self offer';
    for my $right (@$rights) {
        is $right->{plans},          1, "$right->{resource_name}: one payment plan";
        is $right->{one_time_plans}, 1, "$right->{resource_name}: it is one-time";
        ok defined $right->{price_cents} && $right->{price_cents} == 0,
            "$right->{resource_name}: priced at exactly 0";
    }
};

subtest 'revert refuses while a tenant holds solo' => sub {
    my $tenant = $db->query( q{INSERT INTO registry.tenants (name, slug)
                               VALUES ('Solo Holder', 'solo_holder') RETURNING id} )->hash->{id};
    my $entitlement = $db->query( q{
        INSERT INTO registry.entitlements (holder_tenant_id, offer_version_id, payment_plan_id, in_effect)
        VALUES (?, ?, 'revenue_share', tstzrange(now(), NULL, '[)')) RETURNING id
    }, $tenant, $db->query($SOLO_V1)->hash->{id} )->hash->{id};

    my $stderr = capture_stderr {
        dies_ok { $sqitch->run( 'sqitch', 'revert', '-t', $uri, '--to', CHANGE . '^', '-y' ) }
            'the revert fails';
    };
    like $stderr, qr/an entitlement other than the seed's/, 'loudly, naming why';
    is $db->query( 'SELECT count(*) FROM registry.entitlements WHERE id = ?', $entitlement )->array->[0], 1,
        "the tenant's entitlement is kept";
    is $db->query($SOLO_V1)->hashes->size, 1, 'and so is Solo v1';
};

done_testing;
