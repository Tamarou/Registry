# ABOUTME: Test helper for race tests that fork: the child gives up the parent's database connections,
# ABOUTME: and the parent reaps the child with a bound, killing it rather than hanging the test file.
use 5.42.0;
use warnings;

package Test::Registry::Fork;

use DBI;
use POSIX ();
use Exporter 'import';
our @EXPORT_OK = qw( forget_inherited_handles reap );

# Call first in a forked child. A child shares the parent's libpq sockets, so
# any query it runs on an inherited handle (often through a closure over the
# parent's $db) interleaves with the parent's own on one connection: empty
# DBD::Pg errors, SIGSEGV in either process, or both waiting forever for a
# reply the other read. Pointing each inherited socket at /dev/null makes such
# a query fail at once in the child, and leaves the parent's session alone.
sub forget_inherited_handles () {
    open my $null, '+<', '/dev/null' or die "/dev/null: $!";
    DBI->visit_handles( sub ( $h, $info ) {
        if ( $h->{Type} eq 'db' && $h->{Active} ) {
            $h->{InactiveDestroy} = 1;
            POSIX::dup2( fileno $null, $h->{pg_socket} ) // die "dup2: $!";
        }
        return 1;
    } );
    return;
}

# waitpid($pid, 0) with a bound: a child still running after $seconds is
# killed, so $? reads signal 9 instead of the test file never finishing.
sub reap ( $pid, $seconds = 60 ) {
    my $deadline = time + $seconds;
    until ( waitpid( $pid, POSIX::WNOHANG() ) ) {
        if ( time > $deadline ) {
            kill KILL => $pid;
            waitpid $pid, 0;
            return;
        }
        select undef, undef, undef, 0.05;
    }
    return;
}

1;
