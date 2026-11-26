# ABOUTME: The registry.webhook_events row: one Stripe event, claimed once, then stored or marked processed.
# ABOUTME: The webhook endpoints (Controller::Webhooks) record what they did with an event through these methods.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WebhookEvent :isa(Registry::DAO::Object) {
    sub table { 'registry.webhook_events' }

    # Event $event_id is processed, now.
    sub mark_processed ( $class, $db, $event_id ) {
        $db->query(
            q{UPDATE registry.webhook_events SET processed_at = now()
              WHERE stripe_event_id = ?}, $event_id
        );
    }

    # Stores Stripe move $event with its account and tenant id, left
    # unprocessed for whatever applies it.
    sub store_move ( $class, $db, $event, $account, $tenant_id ) {
        $db->query(
            q{UPDATE registry.webhook_events
                 SET account = ?, tenant_id = ?, payload = ?::jsonb
               WHERE stripe_event_id = ?},
            $account, $tenant_id, { json => $event }, $event->{id}
        );
    }

    # Stores $event as store_move does, naming its tenant by slug.
    sub store_move_for_slug ( $class, $db, $event, $account, $slug ) {
        $db->query(
            q{UPDATE registry.webhook_events
                 SET account = ?, payload = ?::jsonb,
                     tenant_id = (SELECT id FROM registry.tenants WHERE slug = ?)
               WHERE stripe_event_id = ?}, $account, { json => $event }, $slug, $event->{id}
        );
    }
}

1;
