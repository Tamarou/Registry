# ABOUTME: Test helpers that give a tenant stated platform terms, for one block or for the rest of a test.
# ABOUTME: Plan rows are immutable, so a test that needs different terms creates a plan rather than editing one.
use 5.42.0;
use warnings;

package Test::Registry::PricingProbe;

use Exporter 'import';
our @EXPORT_OK = qw( with_tenant_plan give_tenant_terms without_rate_check solo_linked_tenant );

use Mojo::JSON qw( encode_json );

# with_tenant_plan($db, $slug, \%overrides, $cb)
#
# Creates a plan copied from the one $slug's tenant is currently linked to, with
# %overrides applied, repoints the tenant at it, runs $cb, then puts the original
# link back and deletes the probe.
#
# Why this shape rather than editing a plan in place, which is what every caller
# used to do: `pricing_plans` rows are immutable, enforced by a trigger, so the
# save/mutate/restore pattern is refused at the database. Repointing is both what
# remains available and a better test -- it follows the same link the resolvers
# follow, and it is how a plan change actually reaches a tenant (#277).
#
# It is also better isolated than what it replaces. The old pattern edited shared
# seed data and restored it at the end of the subtest, so any failure partway
# through left the seed altered for everything that ran next.
#
# `superseded_at` is deliberately not settable through here. Retiring a version is
# a different operation with its own rules (exactly one current version per
# family), and a test that wants it should say so explicitly.
sub with_tenant_plan ( $db, $slug, $overrides, $cb ) {
    my $original = $db->query(
        'SELECT platform_pricing_plan_id FROM registry.tenants WHERE slug = ?',
        $slug )->hash->{platform_pricing_plan_id};

    die "with_tenant_plan: tenant '$slug' has no linked plan to copy"
        unless $original;

    my $made = _probe_plan( $db, $original, $overrides );

    $db->query(
        'UPDATE registry.tenants SET platform_pricing_plan_id = ? WHERE slug = ?',
        $made, $slug );

    my $ok  = eval { $cb->(); 1 };
    my $err = $@;

    # Restored whatever happened, so one failing assertion cannot cascade into
    # every later subtest through the shared tenant row.
    $db->query(
        'UPDATE registry.tenants SET platform_pricing_plan_id = ? WHERE slug = ?',
        $original, $slug );
    $db->query( 'DELETE FROM registry.pricing_plans WHERE id = ?', $made );

    die $err unless $ok;
    return;
}

# give_tenant_terms($db, $slug, { rate => '0.025', amount_cents => 0, name => ... })
#
# Gives $slug's tenant the stated platform terms for the rest of the test: a
# new plan shaped like the seeded revenue-share (Solo) plan, carrying exactly
# this rate, monthly amount and name, which the tenant is then linked to. A
# test that charges money says what it charges under, rather than inheriting
# whatever the seed or the Free fallback happens to carry. No refund flag:
# refunds keep the platform fee for every seller (ADR 003).
#
# Column-backed today; the switch to entitlements re-implements only this.
sub give_tenant_terms ( $db, $slug, $terms ) {
    my $made = _probe_plan( $db, _solo_plan_id($db), {
        plan_name             => $terms->{name} // 'Stated terms',
        amount_cents          => $terms->{amount_cents} // 0,
        pricing_configuration => { percentage => $terms->{rate} },
        metadata              => {},
    } );
    $db->query(
        'UPDATE registry.tenants SET platform_pricing_plan_id = ? WHERE slug = ?',
        $made, $slug );
    return;
}

# The seeded revenue-share plan, by tenant-platform-pricing-plan's backfill predicate.
sub _solo_plan_id ($db) {
    return $db->query( q{
        SELECT id FROM registry.pricing_plans
         WHERE plan_scope = 'tenant'
           AND pricing_model_type = 'percentage'
           AND metadata->>'default' IS DISTINCT FROM 'true'
         ORDER BY created_at
         LIMIT 1
    } )->hash->{id} // die "no revenue-share plan in the seed to shape terms on\n";
}

# A new plan copied from $template_id with %$overrides applied; returns its id.
sub _probe_plan ( $db, $template_id, $overrides ) {
    my $template = $db->query(
        'SELECT * FROM registry.pricing_plans WHERE id = ?', $template_id )
        ->expand->hash;

    my %plan = (
        session_id            => $template->{session_id},
        plan_scope            => $template->{plan_scope},
        plan_name             => 'Probe ' . ( $template->{plan_name} // 'plan' ),
        plan_type             => $template->{plan_type},
        pricing_model_type    => $template->{pricing_model_type},
        currency              => $template->{currency},
        amount_cents          => $template->{amount_cents},
        requirements          => $template->{requirements}          // {},
        pricing_configuration => $template->{pricing_configuration} // {},
        metadata              => $template->{metadata}              // {},
        %$overrides,
    );

    return $db->query( q{
        INSERT INTO registry.pricing_plans
            (session_id, plan_scope, plan_name, plan_type, pricing_model_type,
             currency, amount_cents, requirements, pricing_configuration, metadata)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?::jsonb, ?::jsonb, ?::jsonb)
        RETURNING id
    },  @plan{qw( session_id plan_scope plan_name plan_type pricing_model_type
                  currency amount_cents )},
        map { ref $_ ? encode_json($_) : $_ }
            @plan{qw( requirements pricing_configuration metadata )},
    )->hash->{id};
}

# without_rate_check($db, $cb)
#
# Runs $cb with pricing_plans_percentage_rate_check lifted, in a transaction
# that is rolled back, so a test can plant a rate the database refuses and
# prove the application's own guard still stops it. tenants_plan_has_rate is
# lifted with it, so such a plan can be linked to a tenant.
sub without_rate_check ( $db, $cb ) {
    my $tx = $db->begin;
    $db->query( 'ALTER TABLE registry.pricing_plans DROP CONSTRAINT pricing_plans_percentage_rate_check' );
    $db->query( 'ALTER TABLE registry.tenants DISABLE TRIGGER tenants_plan_has_rate' );
    $cb->();
    return;    # $tx goes out of scope uncommitted: the constraint comes back
}

# solo_linked_tenant($db) -> $slug
#
# A tenant linked to the revenue-share (Solo) plan, made on first call. These
# tests used to find one in the seed, and the only seeded one was the platform
# row -- which takes no share of itself now (platform-tenant-unlinks-solo).
# Solo is found by tenant-platform-pricing-plan's own backfill predicate.
sub solo_linked_tenant ($db) {
    my $slug = 'solo_linked_probe';
    $db->query( q{
        INSERT INTO registry.tenants (name, slug, platform_pricing_plan_id)
        SELECT 'Solo Linked Probe', ?, id FROM registry.pricing_plans
         WHERE plan_scope = 'tenant'
           AND pricing_model_type = 'percentage'
           AND metadata->>'default' IS DISTINCT FROM 'true'
         ORDER BY created_at
         LIMIT 1
        ON CONFLICT (slug) DO NOTHING
    }, $slug );
    die "solo_linked_tenant: no revenue-share plan to link '$slug' to\n"
      unless $db->query( 'SELECT platform_pricing_plan_id FROM registry.tenants WHERE slug = ?', $slug )
        ->hash->{platform_pricing_plan_id};
    return $slug;
}

1;
