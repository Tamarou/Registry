#!/usr/bin/env perl
# ABOUTME: Tenant-aware helpers for the lifecycle E2E: mint tenant-schema login
# ABOUTME: tokens and run JSON-returning read queries against a named schema.
use 5.42.0;
use lib qw(lib t/lib);
use Registry::DAO;
use Registry::DAO::MagicLinkToken;

my ($cmd, @args) = @ARGV;
my $url = $ENV{DB_URL} or die "DB_URL required\n";

if ($cmd eq 'login-token') {
    my ($schema, $user_id) = @args;
    my $dao = Registry::DAO->new(url => $url, schema => $schema); # keep alive
    my (undef, $plaintext) = Registry::DAO::MagicLinkToken->generate(
        $dao->db, { user_id => $user_id, purpose => 'login', expires_in => 24 }
    );
    print $plaintext;
}
elsif ($cmd eq 'query-json') {
    # query-json <schema> <sql-with-?-placeholders> <bind...>
    my ($schema, $sql, @bind) = @args;
    my $dao = Registry::DAO->new(url => $url, schema => $schema); # keep alive
    my $json = $dao->db->query(
        qq{SELECT COALESCE(json_agg(t), '[]'::json)::text AS j FROM ($sql) t}, @bind
    )->hash->{j};
    print $json;
}
else { die "unknown command: $cmd\n" }
