# ABOUTME: Data access object for billing periods across all pricing relationships
# ABOUTME: Tracks billing cycles and payment status for B2B, B2C, and platform billing

use 5.40.2;
use utf8;
use experimental qw(try);
use Object::Pad;

class Registry::DAO::BillingPeriod :isa(Registry::DAO::Object) {
    use Carp qw( croak );
    use List::Util qw( any );
    use Mojo::JSON qw( decode_json encode_json );

    field $id :param :reader;
    field $pricing_relationship_id :param :reader;
    field $period_start :param :reader;
    field $period_end :param :reader;
    field $calculated_amount :param :reader;
    field $payment_status :param :reader = 'pending';
    field $stripe_invoice_id :param :reader = undef;
    field $stripe_payment_intent_id :param :reader = undef;
    field $processed_at :param :reader = undef;
    field $metadata :param :reader = {};
    field $created_at :param :reader;
    field $updated_at :param :reader;

    sub table { 'billing_periods' }

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

        # Validate payment status
        my @valid_statuses = qw(pending processing paid failed refunded);
        unless (any { $_ eq $payment_status } @valid_statuses) {
            croak "Invalid payment_status: $payment_status";
        }
    }

    sub create ($class, $db, $data) {
        # Encode JSON fields
        if (exists $data->{metadata} && ref $data->{metadata}) {
            $data->{metadata} = encode_json($data->{metadata});
        }

        # Set defaults
        $data->{payment_status} //= 'pending';

        my $result = $db->insert('registry.billing_periods', $data, {returning => '*'});

        return $class->new(%{$result->hash});
    }

    sub find ($class, $db, $where = {}) {
        my $results = $db->select('registry.billing_periods', '*', $where);

        my @periods;
        while (my $row = $results->hash) {
            push @periods, $class->new(%$row);
        }

        return @periods;
    }

    sub find_by_id ($class, $db, $id) {
        my $result = $db->select('registry.billing_periods', '*', {id => $id});
        my $row = $result->hash;

        return $row ? $class->new(%$row) : undef;
    }

    method update ($db, $updates) {
        # Encode JSON fields
        if (exists $updates->{metadata} && ref $updates->{metadata}) {
            $updates->{metadata} = encode_json($updates->{metadata});
        }

        my $result = $db->update(
            'registry.billing_periods',
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

    method mark_as_paid ($db, $stripe_invoice_id = undef, $stripe_payment_intent_id = undef) {
        my $updates = {
            payment_status => 'paid',
            processed_at => \'CURRENT_TIMESTAMP'
        };

        $updates->{stripe_invoice_id} = $stripe_invoice_id if $stripe_invoice_id;
        $updates->{stripe_payment_intent_id} = $stripe_payment_intent_id if $stripe_payment_intent_id;

        return $self->update($db, $updates);
    }

    method mark_as_failed ($db, $error_metadata = {}) {
        return $self->update($db, {
            payment_status => 'failed',
            metadata => {%$metadata, error => $error_metadata}
        });
    }

    method get_pricing_relationship ($db) {
        require Registry::DAO::PricingRelationship;
        return Registry::DAO::PricingRelationship->find_by_id($db, $pricing_relationship_id);
    }
}

1;