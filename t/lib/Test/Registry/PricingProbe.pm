# ABOUTME: Test helper that points a tenant at a purpose-built pricing plan for one assertion.
# ABOUTME: Plan rows are immutable, so a test that needs different terms creates a plan rather than editing one.
use 5.42.0;
use warnings;

package Test::Registry::PricingProbe;

use Exporter 'import';
our @EXPORT_OK = qw( with_tenant_plan );

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

    my $template = $db->query(
        'SELECT * FROM registry.pricing_plans WHERE id = ?', $original )
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

    my $made = $db->query( q{
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

1;
