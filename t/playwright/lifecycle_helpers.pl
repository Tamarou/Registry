#!/usr/bin/env perl
# ABOUTME: Tenant-aware helpers for the lifecycle E2E: mint tenant-schema login
# ABOUTME: tokens and run JSON-returning read queries against a named schema.
use 5.42.0;
use experimental 'signatures';
use lib qw(lib t/lib);

my ($cmd, @args) = @ARGV;
my $url = $ENV{DB_URL} or die "DB_URL required\n";

# Loading Registry::DAO costs 6-9 seconds of module compilation per invocation,
# measured, and this script is run once per database assertion -- 19 times in
# morgan.spec.js, 26 in lifecycle.spec.js. That was ~130s of morgan's ~190s
# runtime, all of it invisible to a Playwright trace because it happens between
# actions in a child process (#428).
#
# Only login-token needs the DAO. The two SQL commands need a connection, so
# they build one directly, with the SAME semantics Registry::DAO gives it:
# Mojo::Pg (which is what the DAO uses underneath), the same
# search_path of [$schema, 'public'], and the same client encoding. Anything
# else here would change which schema a tenant query resolves against, and so
# change what every journey asserts.
sub pg_for ($schema) {
    require Mojo::Pg;
    my $pg = Mojo::Pg->new($url);
    $pg->search_path( [ $schema, 'public' ] );
    $pg->on( connection => sub ( $p, $dbh ) {
        $dbh->do("SET client_encoding = 'UTF8'");
    } );
    return $pg;
}

if ($cmd eq 'login-token') {
    my ($schema, $user_id) = @args;
    require Registry::DAO;
    require Registry::DAO::MagicLinkToken;
    my $dao = Registry::DAO->new(url => $url, schema => $schema); # keep alive
    my (undef, $plaintext) = Registry::DAO::MagicLinkToken->generate(
        $dao->db, { user_id => $user_id, purpose => 'login', expires_in => 24 }
    );
    print $plaintext;
}
elsif ($cmd eq 'query-json') {
    # query-json <schema> <sql-with-?-placeholders> <bind...>
    my ($schema, $sql, @bind) = @args;
    my $pg = pg_for($schema); # keep alive
    my $json = $pg->db->query(
        qq{SELECT COALESCE(json_agg(t), '[]'::json)::text AS j FROM ($sql) t}, @bind
    )->hash->{j};
    print $json;
}
elsif ($cmd eq 'exec-sql') {
    # exec-sql <schema> <sql-with-?-placeholders> <bind...>
    # Runs SQL at top level (supports data-modifying statements); prints 'ok'.
    my ($schema, $sql, @bind) = @args;
    my $pg = pg_for($schema); # keep alive
    $pg->db->query($sql, @bind);
    print 'ok';
}
else { die "unknown command: $cmd\n" }
