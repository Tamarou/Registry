#!/usr/bin/env perl
# ABOUTME: The magic-link lifetime has three defaults in three places, and they must agree.
# ABOUTME: A link is a live credential sitting in a mailbox, so the window is the whole mitigation.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::MagicLinkToken;
use Registry::DAO::Tenant;
use Registry::DAO::User;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# #450 settled on one hour: a magic link is how people sign in, so the window
# trades "credential sitting in an inbox" against "opened it on the train and
# has to ask again". The three defaults below are the same decision written
# three times -- the column tenants actually get, the field a Tenant object
# falls back to, and the one MagicLinkToken uses when nobody passes a value --
# so this asserts they agree rather than trusting that they do.
my $EXPECTED_HOURS = 1;

subtest 'the column tenants get' => sub {
    my $default = $db->query( q{
        SELECT column_default
          FROM information_schema.columns
         WHERE table_schema = 'registry'
           AND table_name   = 'tenants'
           AND column_name  = 'magic_link_expiry_hours'
    } )->array->[0];

    like $default, qr/\b$EXPECTED_HOURS\b/,
        "the database hands new tenants $EXPECTED_HOURS hour(s)";
};

subtest 'the field a Tenant falls back to' => sub {
    is Registry::DAO::Tenant->new(
        id => '00000000-0000-0000-0000-000000000000',
        name => 'Fallback', slug => 'fallback',
        created_at => '2026-01-01 00:00:00+00' )->magic_link_expiry_hours,
        $EXPECTED_HOURS,
        'a tenant built without the column agrees with it';
};

subtest 'the window a token actually gets' => sub {
    my $user = Registry::DAO::User->create( $db, {
        username => 'expiry_user', name => 'Expiry', user_type => 'parent',
        email => 'expiry@test.local' } );

    # generate, not create: it is what mints a real link, and the default under
    # test is the one it applies when the caller names no window.
    my ( $token ) = Registry::DAO::MagicLinkToken->generate( $db, {
        user_id => $user->id, purpose => 'login' } );

    # Measured against the row rather than recomputed in Perl: the interval
    # arithmetic is the database's and that is what expires the link.
    my $hours = $db->query(
        'SELECT ROUND(EXTRACT(EPOCH FROM (expires_at - NOW())) / 3600.0) FROM magic_link_tokens WHERE id = ?',
        $token->id )->array->[0];

    is 0 + $hours, $EXPECTED_HOURS,
        "a token minted with no explicit window lasts $EXPECTED_HOURS hour(s)";
};

done_testing;
