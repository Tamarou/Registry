#!/usr/bin/env perl
# ABOUTME: Tenant-aware helpers for the lifecycle E2E: mint tenant-schema login
# ABOUTME: tokens and run JSON-returning read queries against a named schema.
use 5.42.0;
use experimental 'signatures';
use lib qw(lib t/lib);

my ($cmd, @args) = @ARGV;
my $url = $ENV{DB_URL} or die "DB_URL required\n";

# Loading Registry::DAO costs 6-9 seconds of module compilation per invocation,
# measured, and this script runs once per call -- which is why reads no longer
# come here at all: journey_helpers' queryJson uses psql, at ~0.2s (#428).
#
# What is left needs application code rather than SQL. login-token mints a token
# through the DAO. exec-sql writes, and keeps a connection built with the SAME
# semantics Registry::DAO gives it: Mojo::Pg (which is what the DAO uses
# underneath), the same search_path of [$schema, 'public'], and the same client
# encoding. Anything else would change which schema a statement resolves
# against, and so change what a journey asserts.
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
elsif ($cmd eq 'exec-sql') {
    # exec-sql <schema> <sql-with-?-placeholders> <bind...>
    # Runs SQL at top level (supports data-modifying statements); prints 'ok'.
    my ($schema, $sql, @bind) = @args;
    my $pg = pg_for($schema); # keep alive
    $pg->db->query($sql, @bind);
    print 'ok';
}
else { die "unknown command: $cmd\n" }
