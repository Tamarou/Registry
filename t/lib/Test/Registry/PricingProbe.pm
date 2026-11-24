# ABOUTME: Test helpers that give a tenant stated platform terms, as a platform entitlement, for one block or the rest of a test.
# ABOUTME: Offer versions are immutable, so stated terms are a new retired offer version, never an edit to Solo or any other.
use 5.42.0;
use warnings;

package Test::Registry::PricingProbe;

use Exporter 'import';
our @EXPORT_OK = qw( with_tenant_plan give_tenant_terms state_platform_terms without_rate_check solo_linked_tenant );

use Mojo::Home;
use Mojo::JSON qw( encode_json );
use Test::More ();
use Registry::DAO;
use Registry::DAO::Entitlement;
use Registry::DAO::User;
use Registry::DAO::Workflow;
use Test::Registry::Helpers qw( join_tenant publish_offer );
use Registry::PriceOps::PlatformTerms qw( rate_fraction );

my $SOLO_V1 = '00000000-0000-0000-0003-000000000001';

# The refund kinds offer-publishing publishes on payment processing:
# full_until_cutoff needs an occurrence or class, which it is not.
my %PUBLISHABLE_REFUND = map { $_ => 1 } qw( none keep_fee_with_admin_exception );

# with_tenant_plan($db, $slug, { rate, amount_cents, name, refund }, $cb)
#
# Gives $slug's tenant terms copied from the ones it holds now, with the stated
# ones applied, runs $cb, then gives it back the entitlement it held -- whatever
# happened, so one failing assertion cannot cascade into every later subtest
# through the shared tenant. Dies when the tenant holds no platform terms to
# copy. Does not check the rate, so a test inside without_rate_check can plant
# one the database refuses.
sub with_tenant_plan ( $db, $slug, $overrides, $cb ) {
    my $held = _held( $db, $slug );
    die "with_tenant_plan: tenant '$slug' holds no platform terms to copy\n" unless @$held;

    my $now = Registry::PriceOps::PlatformTerms::platform_terms_for_tenant( $db, $slug );
    _hold( $db, $slug, _probe_version( $db, {
        rate         => $now->{fraction},
        amount_cents => $now->{amount_cents},
        name         => 'Probe ' . $now->{name},
        refund       => $now->{refund_policy},
        %$overrides,
    } ) );

    my $ok  = eval { $cb->(); 1 };
    my $err = $@;

    _hold( $db, $slug, undef );
    # Not terms: the exact rows it held back, ids and history included, which no interface re-creates.
    $db->query( q{INSERT INTO registry.entitlements
                  SELECT * FROM jsonb_populate_recordset(NULL::registry.entitlements, ?::jsonb)},
        encode_json($held) );

    die $err unless $ok;
    return;
}

# give_tenant_terms($db, $slug, { rate => '0.025', amount_cents => 0, name => ..., refund => {...} })
#
# Gives $slug's tenant the stated platform terms for the rest of the test: a
# platform entitlement to a new payment-processing offer version carrying
# exactly this rate, price, name and refund policy (Solo's by default), in
# place of whatever it held. A test that charges money says what it charges
# under rather than inheriting whatever the seed happens to grant.
sub give_tenant_terms ( $db, $slug, $terms ) {
    # The resolver's own rule, so the probe refuses exactly what it would read.
    rate_fraction( $terms->{rate}, "give_tenant_terms for tenant '$slug'" );
    _hold( $db, $slug, _probe_version( $db, $terms ) );
    return;
}

# state_platform_terms($db, $slug_or_slugs, { rate => 0, ... })
#
# The `platform terms are stated` subtest a charging test opens with: gives each
# tenant the terms through give_tenant_terms and asserts the resolver answers
# them, so the test says what it charges under.
sub state_platform_terms ( $db, $slugs, $terms ) {
    $db = $db->db if $db isa Registry::DAO;
    Test::More::subtest 'platform terms are stated' => sub {
        for my $slug ( ref $slugs ? @$slugs : $slugs ) {
            give_tenant_terms( $db, $slug, $terms );
            my $got = Registry::PriceOps::PlatformTerms::platform_terms_for_tenant( $db, $slug );
            Test::More::cmp_ok( $got->{fraction}, '==', $terms->{rate},
                "$slug is charged at the stated rate" );
            Test::More::is( $got->{amount_cents}, $terms->{amount_cents} // 0,
                "$slug holds the stated monthly amount" );
        }
    };
    return;
}

# without_rate_check($db, $cb)
#
# Runs $cb with the payment-plan rate checks lifted (range, scale, and a
# percentage plan having a rate at all), in a transaction that is rolled back,
# so a test can plant a rate the database refuses and prove the application's
# own guard still stops it.
# Set while without_rate_check holds its lock: a publishable probe publishes over
# a second connection, which would wait on that lock forever.
our $IN_RATE_BYPASS = 0;

sub without_rate_check ( $db, $cb ) {
    local $IN_RATE_BYPASS = 1;
    my $tx = $db->begin;
    $db->query( 'ALTER TABLE registry.offer_version_payment_plans
                 DROP CONSTRAINT offer_version_payment_plans_fraction_check,
                 DROP CONSTRAINT offer_version_payment_plans_fraction_matches_kind' );
    $cb->();
    return;    # $tx goes out of scope uncommitted: the constraint comes back
}

# solo_linked_tenant($db) -> $slug
#
# A tenant holding the bootstrap's Solo v1, made on first call.
sub solo_linked_tenant ($db) {
    my $slug = 'solo_linked_probe';
    # Not terms: a bare tenant row, with no schema, to hold the seed's Solo v1.
    $db->query( q{INSERT INTO registry.tenants (name, slug) VALUES ('Solo Linked Probe', ?)
                  ON CONFLICT (slug) DO NOTHING}, $slug );
    _hold( $db, $slug, $SOLO_V1 ) unless @{ _held( $db, $slug ) };
    return $slug;
}

# The rows of $slug's platform entitlements to payment processing.
sub _held ( $db, $slug ) {
    return $db->query( q{
        SELECT e.* FROM registry.entitlements e
          JOIN registry.tenants t ON t.id = e.holder_tenant_id
          JOIN registry.offer_versions v ON v.id = e.offer_version_id
          JOIN registry.resources r ON r.id = v.resource_id
         WHERE t.slug = ? AND r.name = 'payment processing'
    }, $slug )->hashes->to_array;
}

# Replaces $slug's platform entitlements to payment processing with one to
# $version_id under its percentage-of-sales plan, in effect from now; none when
# $version_id is undef. Deleted rather than ended: a probe rewrites the
# tenant's history for the test, it is not a lifecycle move.
sub _hold ( $db, $slug, $version_id ) {
    $db->query( 'DELETE FROM registry.entitlements WHERE id = ?', $_->{id} ) for @{ _held( $db, $slug ) };
    return unless $version_id;
    my ( $tenant_id, $plan_id ) = $db->query( q{
        SELECT t.id, p.id FROM registry.tenants t, registry.offer_version_payment_plans p
         WHERE t.slug = ? AND p.offer_version_id = ? AND p.kind = 'percentage_of_sales'
    }, $slug, $version_id )->array->@*;
    Registry::DAO::Entitlement->create( $db, {
        holder_tenant_id => $tenant_id, offer_version_id => $version_id, payment_plan_id => $plan_id,
        starts_at        => 'now' } );
    return;
}

# A new offer for payment processing, named $terms->{name}, with one version
# carrying exactly these terms: published and retired at once, so signup
# never offers it and no published version is edited. Returns the version id.
# Published through offer-publishing by a platform admin, as a real platform
# offer is; only terms the workflow refuses are planted (_planted_version).
sub _probe_version ( $db, $terms ) {
    my $refund = $terms->{refund} // { kind => 'keep_fee_with_admin_exception' };
    my $rate   = eval { rate_fraction( $terms->{rate}, 'a probe' ) };
    return _planted_version( $db, $terms, $refund )
        unless defined $rate && keys %$refund == 1 && $PUBLISHABLE_REFUND{ $refund->{kind} // '' };
    die "a publishable probe can't run inside without_rate_check: it would wait on that lock forever\n"
        if $IN_RATE_BYPASS;

    my $dao = Registry::DAO->new;    # DB_URL's registry schema, where platform offers are published
    # A no-op once stored, so a test that never imported workflows still has it.
    Registry::DAO::Workflow->from_yaml( $dao, Mojo::Home->new->child( 'workflows', 'offer-publishing.yml' )->slurp );
    my $basis_points = sprintf '%.0f', $rate * 10_000;    # whole: rate_fraction refuses finer
    my $version = publish_offer( $dao, 'registry', _platform_admin( $dao->db ), {
        resource_id => $db->query(q{SELECT id FROM registry.resources WHERE name = 'payment processing'})->array->[0],
        offer_name  => $terms->{name} // 'Stated terms',
        price_cents => $terms->{amount_cents} // 0,
        currency    => 'usd',
        units_per_acceptance => 1,
        per_booking_cap      => 1,
        one_time             => 'declined',
        percentage_of_sales  => 'offered',
        rate_percent         => sprintf( '%d.%02d', int( $basis_points / 100 ), $basis_points % 100 ),
        refund               => $refund->{kind},
    } );
    # Retired at once: signup grants the one current platform offer to tenants.
    $db->query( 'UPDATE registry.offer_versions SET superseded_at = now() WHERE id = ?', $version->id );
    return $version->id;
}

# A platform admin, the only one who may publish a platform offer; made on first call.
sub _platform_admin ($db) {
    my $admin = Registry::DAO::User->find( $db, { username => 'pricing_probe_admin' } )
        // Registry::DAO::User->create( $db, { username => 'pricing_probe_admin', name => 'Pricing Probe Admin',
            email => 'pricing_probe_admin@test.local', user_type => 'admin' } );
    join_tenant( $db, $admin, 'admin', 'registry' );
    return $admin;
}

# Planted as rows, because the probe's point is terms offer-publishing refuses:
# a rate the database refuses (planted inside without_rate_check), no rate at
# all, or a refund policy payment processing cannot be published with.
sub _planted_version ( $db, $terms, $refund ) {
    my $offer = $db->query( 'INSERT INTO registry.offers (name) VALUES (?) RETURNING id',
        $terms->{name} // 'Stated terms' )->hash->{id};
    my $version = $db->query( q{
        INSERT INTO registry.offer_versions
            (offer_id, version, resource_id, price_cents, units_per_acceptance, per_booking_cap, policies)
        SELECT ?, 1, id, ?, 1, 1, ?::jsonb FROM registry.resources WHERE name = 'payment processing'
        RETURNING id
    }, $offer, $terms->{amount_cents} // 0, encode_json( { refund => $refund } ) )->hash->{id};
    $db->query( q{INSERT INTO registry.offer_version_payment_plans (offer_version_id, id, kind, fraction)
                  VALUES (?, 'revenue_share', 'percentage_of_sales', ?)}, $version, $terms->{rate} );
    $db->query( 'UPDATE registry.offer_versions SET published_at = now(), superseded_at = now() WHERE id = ?',
        $version );
    return $version;
}

1;
