#!/usr/bin/env perl
# ABOUTME: Playwright test helper that creates a waitlist entry with an active offer.
# ABOUTME: Requires setup_registration_test_data.pl to have run first; reads its JSON from stdin.

use strict;
use warnings;
use 5.34.0;
use experimental 'signatures';

use lib qw(lib t/lib);

use Registry::DAO;
use Registry::DAO::Waitlist;
use JSON::PP qw(decode_json encode_json);

my $db_url = $ENV{DB_URL}
    or die "DB_URL environment variable must be set\n";

# Read base data JSON from command line arguments
my $base_json = shift @ARGV
    or die "Usage: $0 '<base_data_json>'\n";

my $data = decode_json($base_json);

my $dao = Registry::DAO->new(url => $db_url);
my $db  = $dao->db;

# Create a waitlist entry with status='offered' for the returning parent's child
my $entry = Registry::DAO::Waitlist->create($db, {
    session_id       => $data->{sessions}{week3_full}{id},
    location_id      => $data->{location_id},
    student_id       => $data->{returning_parent}{child_id},
    family_member_id => $data->{returning_parent}{child_id},
    parent_id        => $data->{returning_parent}{user_id},
    status           => 'offered',
    position         => 1,
});

# Set offered_at and expires_at
$db->query(
    q{UPDATE waitlist SET offered_at = NOW(), expires_at = NOW() + INTERVAL '48 hours' WHERE id = ?},
    $entry->id,
);

print encode_json({ waitlist_id => $entry->id });
print "\n";
