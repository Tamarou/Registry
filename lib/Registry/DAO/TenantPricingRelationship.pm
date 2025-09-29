# ABOUTME: Data access object for tenant-to-tenant pricing relationships
# ABOUTME: Manages pricing relationships between tenants including platform fees

use 5.40.2;
use utf8;
use experimental qw(try);
use Object::Pad;

class Registry::DAO::TenantPricingRelationship :isa(Registry::DAO::Object) {
    use Carp qw( croak );
    use Mojo::JSON qw( decode_json encode_json );

    field $id :param :reader;
    field $payer_tenant_id :param :reader;
    field $payee_tenant_id :param :reader;
    field $pricing_plan_id :param :reader;
    field $relationship_type :param :reader;
    field $started_at :param :reader;
    field $ended_at :param :reader = undef;
    field $is_active :param :reader = 1;
    field $metadata :param :reader = {};
    field $created_at :param :reader;
    field $updated_at :param :reader;

    sub table { 'tenant_pricing_relationships' }

    ADJUST {
        # Decode JSON fields if they're strings
        if (defined $metadata && !ref $metadata) {
            try {
                $metadata = decode_json($metadata);
            }
            catch ($e) {
                croak "Failed to decode JSON metadata: $e";
            }
        }
    }

    sub create ($class, $db, $data) {
        # Encode JSON fields
        if (exists $data->{metadata} && ref $data->{metadata}) {
            $data->{metadata} = encode_json($data->{metadata});
        }

        # Set defaults
        $data->{is_active} //= 1;
        $data->{started_at} //= \'CURRENT_TIMESTAMP';

        my $result = $db->insert('registry.tenant_pricing_relationships', $data, {returning => '*'});

        return $class->new(%{$result->hash});
    }

    sub find ($class, $db, $where = {}) {
        my $results = $db->select('registry.tenant_pricing_relationships', '*', $where);

        my @relationships;
        while (my $row = $results->hash) {
            push @relationships, $class->new(%$row);
        }

        return @relationships;
    }

    sub find_by_id ($class, $db, $id) {
        my $result = $db->select('registry.tenant_pricing_relationships', '*', {id => $id});
        my $row = $result->hash;

        return $row ? $class->new(%$row) : undef;
    }

    method update ($db, $updates) {
        # Encode JSON fields
        if (exists $updates->{metadata} && ref $updates->{metadata}) {
            $updates->{metadata} = encode_json($updates->{metadata});
        }

        my $result = $db->update(
            'registry.tenant_pricing_relationships',
            $updates,
            {id => $id},
            {returning => '*'}
        );

        my $updated = $result->hash;

        # Update fields
        for my $field (keys %$updated) {
            my $setter = "set_$field";
            if ($self->can($setter)) {
                $self->$setter($updated->{$field});
            }
        }

        return $self;
    }

    method deactivate ($db) {
        return $self->update($db, {
            is_active => 0,
            ended_at => \'CURRENT_TIMESTAMP'
        });
    }

    method get_pricing_plan ($db) {
        require Registry::DAO::PricingPlan;
        return Registry::DAO::PricingPlan->find_by_id($db, $pricing_plan_id);
    }

    method get_payer_tenant ($db) {
        require Registry::DAO::Tenant;
        return Registry::DAO::Tenant->find_by_id($db, $payer_tenant_id);
    }

    method get_payee_tenant ($db) {
        require Registry::DAO::Tenant;
        return Registry::DAO::Tenant->find_by_id($db, $payee_tenant_id);
    }
}

1;