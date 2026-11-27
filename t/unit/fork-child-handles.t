#!/usr/bin/env perl
# ABOUTME: A forked test child cannot use the parent's database connection, and a stuck one is killed.
# ABOUTME: Guards Test::Registry::Fork, which every race test's child calls first and every parent reaps with.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fork qw( forget_inherited_handles reap );
use POSIX ();

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;
my $backend = $db->query('SELECT pg_backend_pid()')->array->[0];

subtest 'the child cannot use the parent connection' => sub {
    pipe( my $parent_reads, my $child_writes ) or die "pipe: $!";
    my $pid = fork() // die "fork: $!";
    unless ($pid) {
        close $parent_reads;
        forget_inherited_handles();
        my $used = eval { $db->query('SELECT 1'); 1 };
        print $child_writes $used ? 'used' : 'refused';
        close $child_writes;
        POSIX::_exit(0);
    }
    close $child_writes;
    reap($pid);
    is do { local $/; readline $parent_reads }, 'refused', 'a query on the inherited handle fails in the child';
    is $db->query('SELECT pg_backend_pid()')->array->[0], $backend, 'and the parent keeps its session';
};

subtest 'a child that exits normally leaves the parent session open' => sub {
    my $pid = fork() // die "fork: $!";
    unless ($pid) {
        forget_inherited_handles();
        exit 0;    # runs destructors, unlike _exit
    }
    reap($pid);
    is $? >> 8, 0, 'the child exited cleanly';
    is $db->query('SELECT pg_backend_pid()')->array->[0], $backend, 'and the parent keeps its session';
};

subtest 'a stuck child is killed' => sub {
    my $pid = fork() // die "fork: $!";
    POSIX::_exit( sleep 600 ) unless $pid;
    my $start = time;
    reap( $pid, 1 );
    is $? & 127, 9, 'reap kills a child that outlives its bound';
    cmp_ok time - $start, '<', 10, 'and does not wait for it';
    ok !kill( 0, $pid ), 'which is gone';
    kill KILL => $pid and waitpid $pid, 0;    # so a failing reap cannot leave it holding the test open
};

done_testing;
