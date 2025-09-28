#!/usr/bin/env perl
# ABOUTME: Database manager for Playwright tests that keeps Test::PostgreSQL instances alive
# ABOUTME: Handles creating, maintaining and cleaning up test databases during Playwright test runs

use 5.40.2;
use strict;
use warnings;
use lib qw(lib t/lib);
use Test::Registry::DB;
use JSON::PP;
use IO::Handle;

STDOUT->autoflush(1);
STDERR->autoflush(1);

my $command = shift @ARGV || 'help';

if ($command eq 'create') {
    # Redirect STDOUT and STDERR to suppress schema deployment output
    # Save original STDOUT for JSON output
    open my $original_stdout, '>&', STDOUT;

    close STDOUT;
    close STDERR;
    open STDOUT, '>/dev/null';
    open STDERR, '>/dev/null';

    # Create a new test database
    my $db = Test::Registry::DB->new();

    # Import basic workflows
    my $dao = $db->db();
    eval {
        $dao->import_workflows(['workflows/tenant-signup.yml']);
    };

    # Restore original STDOUT for JSON output
    close STDOUT;
    open STDOUT, '>&', $original_stdout;

    # Print database info as JSON
    my $info = {
        url => $db->uri,
        pid => $$,
        status => 'ready'
    };

    print JSON::PP->new->encode($info);

    # Keep the process alive to maintain the database
    # Listen for commands on STDIN
    while (my $line = <STDIN>) {
        chomp $line;
        if ($line eq 'SHUTDOWN') {
            last;
        } elsif ($line eq 'PING') {
            print "PONG\n";
        }
    }

    # Cleanup happens automatically when process exits

} elsif ($command eq 'help') {
    print "Usage: $0 create\n";
    print "Commands:\n";
    print "  create - Create a test database and keep it alive\n";
    exit(1);
} else {
    print STDERR "Unknown command: $command\n";
    exit(1);
}