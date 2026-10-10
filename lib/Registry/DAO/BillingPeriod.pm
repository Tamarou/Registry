# ABOUTME: Data access object for billing periods across all pricing relationships
# ABOUTME: Tracks billing cycles and payment status for B2B, B2C, and platform billing

use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::BillingPeriod :isa(Registry::DAO::Object) {
    use Carp qw( croak );
    use List::Util qw( any );
    use Mojo::JSON   qw( from_json );

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
        # from_json, not decode_json. decode_json decodes BYTES; Postgres hands
        # back a jsonb column as characters, so decode_json dies with "Input is
        # not UTF-8 encoded" on anything non-ASCII. This used to work only
        # because the write side was equally wrong: it stored double-encoded
        # bytes, and reading those back gave characters whose bytes happened to
        # be valid UTF-8, so the two errors cancelled and the mojibake survived
        # the round trip looking fine. Fixing the write side (#485) exposes this
        # half.
        if (defined $metadata && !ref $metadata) {
            try {
                $metadata = from_json($metadata);
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
            # -json, not encode_json. encode_json returns UTF-8 ENCODED BYTES,
            # and handing those to a jsonb column gets them encoded a second
            # time on the way to Postgres -- so an accented character is stored
            # as the two characters its UTF-8 bytes look like in Latin-1,
            # corrupted on WRITE where no read-path fix recovers it. Mojo::Pg's
            # -json takes the structure and encodes it exactly once (#485).
            $data->{metadata} = { -json => $data->{metadata} };
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
            $updates->{metadata} = { -json => $updates->{metadata} };
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