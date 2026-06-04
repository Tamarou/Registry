#!/usr/bin/env perl
# ABOUTME: Provisions one shared Test::PostgreSQL database for a whole Playwright run.
# ABOUTME: Imports all workflows/templates, prints {url,pid} JSON, stays alive until SHUTDOWN.
use 5.42.0;
use strict;
use warnings;
use FindBin ();
use lib qw(lib t/lib);
use Test::Registry::DB;
use JSON::PP;
use IO::Handle;

STDOUT->autoflush(1);

# Anchor to repo root so ./registry and workflows/ resolve no matter the cwd.
chdir "$FindBin::RealBin/../.." or die "chdir repo root: $!";

# Build the DB. Test::Registry::DB loads the schema from sql/test-schema.sql and
# sets $ENV{DB_URL} to this DB -- which the CLI imports below inherit.
# Suppress the loader/import chatter so STDOUT carries only our JSON line.
open my $orig, '>&', STDOUT or die $!;
open STDOUT, '>', '/dev/null' or die $!;
my $db = Test::Registry::DB->new;

# Import all workflows AND templates exactly as production boot does. Templates
# live on the app (Registry::import_templates at lib/Registry.pm:694), not the
# DAO, so drive both through the CLI under the same perl/@INC.
for my $kind (qw(workflow template)) {
    system( $^X, '-Ilib', './registry', $kind, 'import', 'registry' ) == 0
        or warn "$kind import failed (\$?=$?)\n";
}
open STDOUT, '>&', $orig or die $!;

print JSON::PP->new->encode({ url => $db->uri, pid => $$, status => 'ready' }), "\n";

# Stay alive so the DB persists for the whole run.
while ( my $line = <STDIN> ) {
    chomp $line;
    last if $line eq 'SHUTDOWN';
}
# Test::PostgreSQL tears down on exit.
