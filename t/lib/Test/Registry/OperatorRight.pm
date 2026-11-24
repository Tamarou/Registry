# ABOUTME: Test helper taking the operator right away and back, as registry's entitlement to the operator resource.
# ABOUTME: Also records a $0 entitlement to a named resource in any schema, for the cases that must grant nothing.
use 5.42.0;
use warnings;

package Test::Registry::OperatorRight;

use Exporter 'import';
our @EXPORT_OK = qw( revoke_operator restore_operator grant_in_schema );

use Registry::DAO::Resource;
use Registry::DAO::Offer;
use Registry::DAO::Entitlement;
use Test::Registry::Offers qw( offer_terms );

# Deletes registry's entitlements to the operator resource for real, so the
# app's own connection sees it; returns them for restore_operator.
sub revoke_operator ($db) {
    return $db->query( q{
        DELETE FROM registry.entitlements e
         USING registry.offer_versions v, registry.resources r
         WHERE v.id = e.offer_version_id AND r.id = v.resource_id AND r.name = 'operator'
        RETURNING e.*
    } )->hashes->to_array;
}

sub restore_operator ( $db, $rows ) {
    $db->insert( 'registry.entitlements', $_ ) for @$rows;
}

# Records, in $schema's own tables, $tenant_id holding a new resource named
# $resource from $starts_at (default now). Returns the entitlement.
sub grant_in_schema ( $dao, $schema, $tenant_id, $resource, $starts_at = 'now' ) {
    my $db = $dao->connect_schema($schema)->db;
    # A cloned schema's copy of tenants starts empty; the holder must be a row there.
    $db->query( q{
        INSERT INTO tenants (id, name, slug)
        SELECT id, name, slug FROM registry.tenants WHERE id = ? ON CONFLICT DO NOTHING
    }, $tenant_id );
    my $held    = Registry::DAO::Resource->create( $db, { name => $resource, kind => 'unbounded' } );
    my $version = Registry::DAO::Offer->create( $db, { name => "Grant $resource" } )
        ->draft( $db, offer_terms( $held->id, price_cents => 0 ) )->publish($db);
    return Registry::DAO::Entitlement->create( $db, {
        holder_tenant_id => $tenant_id,
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
        starts_at        => $starts_at,
    } );
}

1;
