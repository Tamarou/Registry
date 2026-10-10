# ABOUTME: Every jsonb column that a DAO writes must survive a non-ASCII round trip.
# ABOUTME: encode_json returns BYTES, and handing those to jsonb encodes them twice.
#
# #485. Mojo::JSON::encode_json returns UTF-8 encoded bytes. Passing those to a
# jsonb column gets them encoded a second time on the way to Postgres, so an
# accented character is stored as the two characters its UTF-8 bytes look like
# in Latin-1 -- corrupted ON WRITE, which no read-path fix recovers.
#
# Every assertion here reads `col::text` straight out of Postgres as well as
# through the DAO. That is the whole point: encode and decode are symmetric, so
# a value can look correct in memory while the stored one is wrong, which is
# exactly how this survived. An in-memory-only assertion would pass against the
# bug.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';

use Test::Registry::DB;
use Registry::DAO;
use Registry::DAO::User;
use Registry::DAO::Tenant;
use Registry::DAO::UserPreference;
use Registry::DAO::PricingRelationship;
use Registry::DAO::PricingRelationshipEvent;
use Registry::DAO::BillingPeriod;
use Registry::DAO::Payment;

# Payment's constructor reaches for a Stripe client, as its siblings' tests do.
local $ENV{STRIPE_SECRET_KEY} = 'sk_test_json_round_trip';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# One string that exercises the failure in three scripts plus an emoji, so a
# fix that only handles Latin-1 accents is not mistaken for a fix.
my $ACCENTED = 'José Müller — 日本 🎉';

sub stored_text ( $sql, @bind ) {
    return $db->query( $sql, @bind )->hash->{t};
}

# A value is correct only if Postgres holds the characters, not their bytes.
sub assert_round_trip ( $label, $stored, $in_memory ) {
    unlike $stored, qr/Ã|Â|â\x{80}/,
        "$label: Postgres holds no mojibake";
    like $stored, qr/\QJosé Müller\E/,
        "$label: the accented text survived to Postgres";
    like $stored, qr/\Q日本\E/, "$label: and so did the CJK";
    is $in_memory, $ACCENTED, "$label: and it reads back through the DAO";
}

my $parent = Registry::DAO::User->create( $db, {
    username => 'jrt_parent', name => 'JRT', user_type => 'parent',
    email => 'jrt@test.local' } );

# provider_id references registry.tenants and consumer_id references
# registry.users -- not two tenants, which is the obvious guess and what the
# first draft of this test got wrong.
my $seq = 0;
sub a_relationship () {
    $seq++;
    my $plan = $db->query( q{SELECT id FROM registry.pricing_plans LIMIT 1} )->hash
        or die 'no pricing plan in the test schema to hang a relationship on';
    my $provider = Registry::DAO::Tenant->create( $db, {
        name => "JRT Provider $seq", slug => "jrt_provider_$seq" } );
    my $consumer = Registry::DAO::User->create( $db, {
        username => "jrt_consumer_$seq", name => "JRT Consumer $seq",
        user_type => 'admin', email => "jrt_consumer_$seq\@test.local" } );
    return Registry::DAO::PricingRelationship->create( $db, {
        provider_id     => $provider->id,
        consumer_id     => $consumer->id,
        pricing_plan_id => $plan->{id},
    } );
}

subtest 'user_preferences.preference_value' => sub {
    Registry::DAO::UserPreference->create( $db, {
        user_id => $parent->id, preference_key => 'jrt',
        preference_value => { note => $ACCENTED } } );

    my $stored = stored_text(
        'SELECT preference_value::text AS t FROM user_preferences
          WHERE user_id = ? AND preference_key = ?', $parent->id, 'jrt' );
    my ($pref) = Registry::DAO::UserPreference->find( $db,
        { user_id => $parent->id, preference_key => 'jrt' } );

    assert_round_trip( 'UserPreference', $stored, $pref->preference_value->{note} );
};

subtest 'pricing_relationships.metadata, on create and on update' => sub {
    my $rel = a_relationship();
    $rel->update( $db, { metadata => { note => $ACCENTED } } );

    my $sql = 'SELECT metadata::text AS t FROM registry.pricing_relationships WHERE id = ?';
    assert_round_trip( 'PricingRelationship->update',
        stored_text( $sql, $rel->id ),
        Registry::DAO::PricingRelationship->find_by_id( $db, $rel->id )->metadata->{note} );

    # create takes the same path and had the same bug.
    my $direct = a_relationship();
    $direct->update( $db, { metadata => { note => $ACCENTED } } );
    my $fresh = Registry::DAO::PricingRelationship->create( $db, {
        provider_id     => $direct->provider_id,
        consumer_id     => $direct->consumer_id,
        pricing_plan_id => $direct->pricing_plan_id,
        status          => 'cancelled',
        metadata        => { note => $ACCENTED },
    } );
    assert_round_trip( 'PricingRelationship->create',
        stored_text( $sql, $fresh->id ),
        Registry::DAO::PricingRelationship->find_by_id( $db, $fresh->id )->metadata->{note} );
};

subtest 'pricing_relationship_events.event_data' => sub {
    my $rel = a_relationship();

    my $event = Registry::DAO::PricingRelationshipEvent->create( $db, {
        relationship_id => $rel->id, event_type => 'created',
        actor_user_id   => $parent->id,
        event_data      => { note => $ACCENTED } } );

    my $stored = stored_text(
        'SELECT event_data::text AS t FROM registry.pricing_relationship_events WHERE id = ?',
        $event->id );
    # find() returns a LIST here, not an object -- scalar context gives the
    # count, which arrives as a confusing "method on package 1".
    my ($back) = Registry::DAO::PricingRelationshipEvent->find( $db, { id => $event->id } );
    assert_round_trip( 'PricingRelationshipEvent', $stored, $back->event_data->{note} );
};

subtest 'billing_periods.metadata, on create and on update' => sub {
    my $rel = a_relationship();

    my $period = Registry::DAO::BillingPeriod->create( $db, {
        pricing_relationship_id => $rel->id,
        period_start => '2026-01-01', period_end => '2026-01-31',
        calculated_amount => 1000,
        metadata => { note => $ACCENTED } } );

    my $sql = 'SELECT metadata::text AS t FROM registry.billing_periods WHERE id = ?';
    assert_round_trip( 'BillingPeriod->create',
        stored_text( $sql, $period->id ),
        ( Registry::DAO::BillingPeriod->find( $db, { id => $period->id } ) )[0]->metadata->{note} );

    $period->update( $db, { metadata => { note => $ACCENTED, second => 'pass' } } );
    assert_round_trip( 'BillingPeriod->update',
        stored_text( $sql, $period->id ),
        ( Registry::DAO::BillingPeriod->find( $db, { id => $period->id } ) )[0]->metadata->{note} );
};

subtest 'payment_items.metadata' => sub {
    # The money path. Today only child_id and session_id ride here -- both
    # uuids -- so this is latent rather than live; the child's NAME goes in
    # `description`, which is a text column and never passed through
    # encode_json. Asserted anyway, because "no non-ASCII reaches it" is a
    # property of today's callers and not of the column.
    my $payment = Registry::DAO::Payment->create( $db, {
        user_id => $parent->id, amount_cents => 5000, status => 'pending',
        metadata => { enrollment_items => [] } } );

    $payment->add_line_item( $db, {
        description  => "José Müller — seat",
        amount_cents => 5000,
        metadata     => { note => $ACCENTED } } );

    my $stored = stored_text(
        'SELECT metadata::text AS t FROM payment_items WHERE payment_id = ?',
        $payment->id );
    my $items = $payment->line_items($db);
    assert_round_trip( 'payment_items', $stored, $items->[0]{metadata}{note} );

    # And the sibling text column, which was never broken, to pin that it stays
    # that way if someone "fixes" it too.
    my $desc = stored_text(
        'SELECT description AS t FROM payment_items WHERE payment_id = ?', $payment->id );
    like $desc, qr/\QJosé Müller\E/, 'the description text column is also clean';
};

done_testing;
