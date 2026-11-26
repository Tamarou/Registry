#!/usr/bin/env perl
# ABOUTME: Every Registry::DAO connection runs in UTC whatever the server's default zone is,
# ABOUTME: so a bare ::date, date_trunc or the text of a timestamptz never depends on server config.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO;

my $test_db = Test::Registry::DB->new;

# A server whose default is not UTC: the setting applies to connections made after it.
$test_db->db->db->query(
    q{SELECT set_config('timezone', 'America/New_York', false)} );
my $dbname = $test_db->db->db->query('SELECT current_database()')->array->[0];
$test_db->db->db->query(qq{ALTER DATABASE "$dbname" SET timezone = 'America/New_York'});

subtest 'a new DAO connection is in UTC under a non-UTC server default' => sub {
    my $dao = Registry::DAO->new( url => $test_db->uri );
    is $dao->db->query('SHOW TimeZone')->array->[0], 'UTC', 'the session zone is UTC';
    is $dao->db->query(q{SELECT ('2027-03-14 03:30:00+00'::timestamptz)::date::text})->array->[0],
        '2027-03-14', 'a bare ::date reads the UTC calendar day, not New York\'s';
};

subtest 'a tenant-schema DAO connection is in UTC too' => sub {
    my $dao = Registry::DAO->new( url => $test_db->uri )->connect_schema('registry');
    is $dao->db->query('SHOW TimeZone')->array->[0], 'UTC', 'the session zone is UTC';
};

done_testing;
