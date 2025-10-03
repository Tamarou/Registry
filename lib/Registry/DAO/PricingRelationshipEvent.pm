# ABOUTME: Data access object for pricing relationship events with event sourcing
# ABOUTME: Provides audit trail and state reconstruction for pricing relationships

use 5.40.2;
use utf8;
use experimental qw(try);
use Object::Pad;

class Registry::DAO::PricingRelationshipEvent :isa(Registry::DAO::Object) {
    use Carp qw( croak );
    use Mojo::JSON qw( decode_json encode_json );

    field $id :param :reader;
    field $relationship_id :param :reader;
    field $event_type :param :reader;
    field $actor_user_id :param :reader;
    field $event_data :param :reader = {};
    field $occurred_at :param :reader;
    field $sequence_number :param :reader = undef;
    field $aggregate_version :param :reader = 1;

    sub table { 'pricing_relationship_events' }

    ADJUST {
        # Decode JSON fields if they're strings
        if (defined $event_data && !ref $event_data) {
            try {
                $event_data = decode_json($event_data);
            }
            catch ($e) {
                croak "Failed to decode JSON event_data: $e";
            }
        }

        # Validate event type
        my @valid_types = qw(
            created activated suspended terminated
            plan_changed billing_updated metadata_updated
        );
        unless (grep { $_ eq $event_type } @valid_types) {
            croak "Invalid event_type: $event_type. Must be one of: " . join(', ', @valid_types);
        }
    }

    # Create a new event
    sub create ($class, $db, $data) {
        # Validate required fields
        for my $field (qw(relationship_id event_type actor_user_id)) {
            croak "$field is required" unless defined $data->{$field};
        }

        # Encode JSON fields
        if (exists $data->{event_data} && ref $data->{event_data}) {
            $data->{event_data} = encode_json($data->{event_data});
        }

        # Get next aggregate version
        my $version_result = $db->query(
            'SELECT get_next_aggregate_version(?) as version',
            $data->{relationship_id}
        );
        $data->{aggregate_version} = $version_result->hash->{version};

        # Insert the event
        my $result = $db->insert('registry.pricing_relationship_events', $data, {returning => '*'});

        return $class->new(%{$result->hash});
    }

    # Find events by criteria
    sub find ($class, $db, $where = {}) {
        my $results = $db->select('registry.pricing_relationship_events', '*', $where, {
            -desc => 'sequence_number'
        });

        my @events;
        while (my $row = $results->hash) {
            push @events, $class->new(%$row);
        }

        return @events;
    }

    # Find all events for a relationship
    sub find_by_relationship ($class, $db, $relationship_id) {
        return $class->find($db, { relationship_id => $relationship_id });
    }

    # Find events for a relationship within a time range
    sub find_by_relationship_and_time ($class, $db, $relationship_id, $start_time, $end_time = undef) {
        my $query = q{
            SELECT * FROM registry.pricing_relationship_events
            WHERE relationship_id = ?
            AND occurred_at >= ?
        };

        my @params = ($relationship_id, $start_time);

        if (defined $end_time) {
            $query .= ' AND occurred_at <= ?';
            push @params, $end_time;
        }

        $query .= ' ORDER BY sequence_number DESC';

        my $results = $db->query($query, @params);

        my @events;
        while (my $row = $results->hash) {
            push @events, $class->new(%$row);
        }

        return @events;
    }

    # Get the latest event for a relationship
    sub get_latest_for_relationship ($class, $db, $relationship_id) {
        my $result = $db->query(q{
            SELECT * FROM registry.pricing_relationship_events
            WHERE relationship_id = ?
            ORDER BY sequence_number DESC
            LIMIT 1
        }, $relationship_id);

        my $row = $result->hash;
        return $row ? $class->new(%$row) : undef;
    }

    # Reconstruct relationship state at a point in time
    sub get_state_at_time ($class, $db, $relationship_id, $timestamp) {
        my $result = $db->query(
            'SELECT * FROM get_relationship_state_at(?, ?)',
            $relationship_id,
            $timestamp
        );

        return $result->hash;
    }

    # Create standard events for common operations
    sub record_creation ($class, $db, $relationship_id, $actor_id, $initial_data = {}) {
        return $class->create($db, {
            relationship_id => $relationship_id,
            event_type => 'created',
            actor_user_id => $actor_id,
            event_data => {
                pricing_plan_id => $initial_data->{pricing_plan_id},
                provider_id => $initial_data->{provider_id},
                consumer_id => $initial_data->{consumer_id},
                relationship_type => $initial_data->{relationship_type},
                %{$initial_data->{metadata} || {}},
            }
        });
    }

    sub record_activation ($class, $db, $relationship_id, $actor_id, $reason = undef) {
        return $class->create($db, {
            relationship_id => $relationship_id,
            event_type => 'activated',
            actor_user_id => $actor_id,
            event_data => {
                reason => $reason,
                activated_at => time(),
            }
        });
    }

    sub record_suspension ($class, $db, $relationship_id, $actor_id, $reason = undef) {
        return $class->create($db, {
            relationship_id => $relationship_id,
            event_type => 'suspended',
            actor_user_id => $actor_id,
            event_data => {
                reason => $reason,
                suspended_at => time(),
            }
        });
    }

    sub record_termination ($class, $db, $relationship_id, $actor_id, $reason = undef) {
        return $class->create($db, {
            relationship_id => $relationship_id,
            event_type => 'terminated',
            actor_user_id => $actor_id,
            event_data => {
                reason => $reason,
                terminated_at => time(),
            }
        });
    }

    sub record_plan_change ($class, $db, $relationship_id, $actor_id, $old_plan_id, $new_plan_id, $reason = undef) {
        return $class->create($db, {
            relationship_id => $relationship_id,
            event_type => 'plan_changed',
            actor_user_id => $actor_id,
            event_data => {
                old_plan_id => $old_plan_id,
                new_plan_id => $new_plan_id,
                reason => $reason,
                changed_at => time(),
            }
        });
    }

    sub record_metadata_update ($class, $db, $relationship_id, $actor_id, $old_metadata, $new_metadata, $reason = undef) {
        return $class->create($db, {
            relationship_id => $relationship_id,
            event_type => 'metadata_updated',
            actor_user_id => $actor_id,
            event_data => {
                old_metadata => $old_metadata,
                new_metadata => $new_metadata,
                reason => $reason,
                updated_at => time(),
            }
        });
    }

    # Get audit trail for a relationship
    sub get_audit_trail ($class, $db, $relationship_id) {
        my @events = $class->find_by_relationship($db, $relationship_id);

        my @trail;
        for my $event (@events) {
            # Get actor information
            require Registry::DAO::User;
            my $actor = Registry::DAO::User->find($db, { id => $event->actor_user_id });

            push @trail, {
                event_type => $event->event_type,
                occurred_at => $event->occurred_at,
                actor => $actor ? {
                    id => $actor->id,
                    name => $actor->name || 'Unknown User',
                } : { id => $event->actor_user_id, name => 'System User' },
                data => $event->event_data,
                sequence_number => $event->sequence_number,
                aggregate_version => $event->aggregate_version,
            };
        }

        return \@trail;
    }

    # Helper method to check if relationship can transition to a new state
    sub can_transition ($class, $db, $relationship_id, $from_state, $to_state) {
        my $latest = $class->get_latest_for_relationship($db, $relationship_id);
        return 0 unless $latest;

        # Define valid transitions
        my %transitions = (
            created => [qw(activated suspended terminated)],
            activated => [qw(suspended terminated plan_changed billing_updated metadata_updated)],
            suspended => [qw(activated terminated)],
            terminated => [],  # Terminal state
            plan_changed => [qw(suspended terminated plan_changed billing_updated metadata_updated)],
            billing_updated => [qw(suspended terminated plan_changed billing_updated metadata_updated)],
            metadata_updated => [qw(suspended terminated plan_changed billing_updated metadata_updated)],
        );

        my $current_type = $latest->event_type;
        my $allowed = $transitions{$current_type} || [];

        return scalar(grep { $_ eq $to_state } @$allowed) > 0;
    }
}

1;