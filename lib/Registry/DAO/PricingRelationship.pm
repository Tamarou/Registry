# ABOUTME: Data access object for unified pricing relationships
# ABOUTME: Manages all pricing relationships - platform, B2C enrollments, and B2B partnerships

use 5.40.2;
use utf8;
use experimental qw(try);
use Object::Pad;

class Registry::DAO::PricingRelationship :isa(Registry::DAO::Object) {
    use Carp qw( croak );
    use Mojo::JSON qw( decode_json encode_json );

    field $id :param :reader;
    field $provider_id :param :reader;
    field $consumer_id :param :reader;
    field $pricing_plan_id :param :reader;
    field $status :param :reader = 'active';
    field $metadata :param :reader = {};
    field $created_at :param :reader;
    field $updated_at :param :reader;

    sub table { 'pricing_relationships' }

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

        # Validate status
        my @valid_statuses = qw(pending active suspended cancelled);
        unless (grep { $_ eq $status } @valid_statuses) {
            croak "Invalid status: $status. Must be one of: " . join(', ', @valid_statuses);
        }
    }

    sub create ($class, $db, $data) {
        # Encode JSON fields
        if (exists $data->{metadata} && ref $data->{metadata}) {
            $data->{metadata} = encode_json($data->{metadata});
        }

        # Set defaults
        $data->{status} //= 'active';

        my $result = $db->insert('registry.pricing_relationships', $data, {returning => '*'});

        return $class->new(%{$result->hash});
    }

    sub find ($class, $db, $where = {}) {
        my $results = $db->select('registry.pricing_relationships', '*', $where);

        my @relationships;
        while (my $row = $results->hash) {
            push @relationships, $class->new(%$row);
        }

        return @relationships;
    }

    sub find_by_id ($class, $db, $id) {
        my $result = $db->select('registry.pricing_relationships', '*', {id => $id});
        my $row = $result->hash;

        return $row ? $class->new(%$row) : undef;
    }

    method update ($db, $updates) {
        # Encode JSON fields
        if (exists $updates->{metadata} && ref $updates->{metadata}) {
            $updates->{metadata} = encode_json($updates->{metadata});
        }

        my $result = $db->update(
            'registry.pricing_relationships',
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

    # Status transition methods
    method activate ($db) {
        return $self->update($db, {
            status => 'active',
            metadata => {
                %$metadata,
                activated_at => time(),
            }
        });
    }

    method suspend ($db) {
        return $self->update($db, {
            status => 'suspended',
            metadata => {
                %$metadata,
                suspended_at => time(),
            }
        });
    }

    method cancel ($db) {
        return $self->update($db, {
            status => 'cancelled',
            metadata => {
                %$metadata,
                cancelled_at => time(),
            }
        });
    }

    # Relationship type detection
    method get_relationship_type ($db) {
        # Platform billing: provider is platform
        if ($provider_id eq '00000000-0000-0000-0000-000000000000') {
            return 'platform_billing';
        }

        # Check if consumer has a tenant association
        my $consumer_tenant = $self->get_consumer_tenant($db);
        if ($consumer_tenant) {
            # B2B: consumer is associated with a tenant
            my $pricing_plan = $self->get_pricing_plan($db);
            if ($pricing_plan && $pricing_plan->plan_scope eq 'tenant') {
                return 'b2b_partnership';
            }
        }

        # B2C: default for consumer without tenant association
        return 'b2c_enrollment';
    }

    # Helper methods to get related objects
    method get_pricing_plan ($db) {
        require Registry::DAO::PricingPlan;
        return Registry::DAO::PricingPlan->find_by_id($db, $pricing_plan_id);
    }

    method get_provider_tenant ($db) {
        require Registry::DAO::Tenant;
        return Registry::DAO::Tenant->find_by_id($db, $provider_id);
    }

    method get_consumer_user ($db) {
        require Registry::DAO::User;
        return Registry::DAO::User->find($db, { id => $consumer_id });
    }

    method get_consumer_tenant ($db) {
        my $user = $self->get_consumer_user($db);
        return unless $user;

        # Check if user is associated with a tenant via tenant_users table
        my $result = $db->query(q{
            SELECT tenant_id FROM tenant_users
            WHERE user_id = ?
            AND is_primary = true
            LIMIT 1
        }, $consumer_id);

        my $row = $result->hash;
        return unless $row && $row->{tenant_id};

        require Registry::DAO::Tenant;
        return Registry::DAO::Tenant->find_by_id($db, $row->{tenant_id});
    }

    # Find active relationships for a consumer
    sub find_active_for_consumer ($class, $db, $consumer_id) {
        return $class->find($db, {
            consumer_id => $consumer_id,
            status => ['active', 'pending'],
        });
    }

    # Find all relationships for a provider
    sub find_for_provider ($class, $db, $provider_id, $status = undef) {
        my $where = { provider_id => $provider_id };
        $where->{status} = $status if defined $status;

        return $class->find($db, $where);
    }

    # Check if a relationship exists between provider and consumer
    sub exists_between ($class, $db, $provider_id, $consumer_id) {
        my @existing = $class->find($db, {
            provider_id => $provider_id,
            consumer_id => $consumer_id,
            status => ['active', 'pending'],
        });

        return scalar @existing > 0;
    }
}

1;