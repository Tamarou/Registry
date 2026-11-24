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
use Registry::DAO::UserPreference;
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
