#!/usr/bin/env perl
# ABOUTME: Regression test for the Test::Registry::DB teardown-order exit-code bug (#186).
# ABOUTME: Verifies handles are neutralized at exit so the ephemeral server stop can't dirty $?.

use 5.42.0;
use warnings;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;

# Background: under the CI postgres environment, a DBD::Pg connection handle
# destroyed against an about-to-stop (or already terminated) server emits
# "terminating connection due to administrator command" / "no connection to
# the server" and dirties the process exit code. prove then reports the test
# file as failed even though every assertion passed. This was the root cause
# behind the chronically-skipped Stripe tests (#186).
#
# Test::Registry::DB defends against this by marking all open DBI connection
# handles InactiveDestroy at process exit (before global destruction), so the
# handle destructors never talk to the server. These tests pin that behaviour.

subtest 'teardown marks db handles InactiveDestroy' => sub {
    my $t   = Test::Registry::DB->new;
    my $dao = $t->db;
    my $dbh = $dao->db->dbh;

    ok( !$dbh->{InactiveDestroy}, 'db handle is active during the test' );

    Test::Registry::DB::_neutralize_dbi_handles();

    ok( $dbh->{InactiveDestroy},
        'neutralize marks the db handle InactiveDestroy so DESTROY is silent' );
};

# Invariant check: a process that retains a DB handle and stops the ephemeral
# server must still exit cleanly, with no DBD::Pg teardown noise on stderr.
subtest 'child process exits cleanly after server teardown' => sub {
    use File::Temp qw(tempfile);

    my $child = <<'PERL';
use lib qw(lib t/lib);
use Test::Registry::DB;

my $t   = Test::Registry::DB->new;
my $dao = $t->db;
my $db  = $dao->db;              # retained Mojo::Pg connection
$db->query('SELECT 1');          # connection is live
$db->query('BEGIN');             # leave a transaction open so teardown must
$db->query('CREATE TEMP TABLE t (x int)');   # roll back against the server

$t->cleanup_test_database;       # stop the ephemeral server while $db is open
exit 0;                          # $db destroyed during exit, server already gone
PERL

    my ( $fh, $script ) = tempfile( SUFFIX => '.pl', UNLINK => 1 );
    print {$fh} $child;
    close $fh;

    my $stderr_file = "$script.err";
    my $status      = system("$^X $script 2>$stderr_file");
    my $exit        = $status >> 8;

    my $stderr = do {
        open my $e, '<', $stderr_file or die "open $stderr_file: $!";
        local $/;
        <$e>;
    } // '';
    unlink $stderr_file;

    is( $exit, 0, 'child process exits 0 after DB teardown' )
        or diag "child stderr:\n$stderr";

    unlike(
        $stderr,
        qr/no connection to the server|terminating connection due to administrator command/,
        'no DBD::Pg teardown noise on child stderr'
    ) or diag "child stderr:\n$stderr";
};

done_testing;
