#!/usr/bin/env perl
# ABOUTME: Guards perigrin's rule that SQL lives in the DAO: no file under lib/ outside lib/Registry/DAO
# ABOUTME: calls query/select/insert/update/delete on a database handle, beyond an allowlist that may only shrink.
use 5.42.0;
use warnings;
use Test::More;
use Mojo::File qw( path );

# The calls that predate the rule (follow-up 01a215f7-c107-7ab1-bf6b-2689b4eea948
# moves them). A count may only go down: lower it here when a call moves, and
# never raise it or add a file.
my %ALLOWED = (
    'lib/Mojolicious/Plugin/DBTemplates.pm'     => 1,
    'lib/Registry.pm'                           => 4,
    'lib/Registry/Command/workflow.pm'          => 2,
    'lib/Registry/Controller/AdminDashboard.pm' => 1,
    'lib/Registry/Controller/Messages.pm'       => 5,
    'lib/Registry/Controller/Waitlist.pm'       => 1,
    'lib/Registry/Controller/Webhooks.pm'       => 26,
    'lib/Registry/Controller/Workflows.pm'      => 7,
    'lib/Registry/Job/DomainVerification.pm'    => 2,
    'lib/Registry/Job/ProcessWaitlist.pm'       => 3,
    'lib/Registry/Job/SendNotifications.pm'     => 4,
    'lib/Registry/Job/ExpireEntitlements.pm'    => 1,
    'lib/Registry/Job/InstalmentReconcile.pm'   => 3,
    'lib/Registry/WorkflowDivergence.pm'        => 3,
);

# A database handle ($db, $tdb, ...->db, a Registry::DAO in $dao) receiving one
# of Mojo::Pg::Database's SQL methods. A DAO object's own ->update($db, ...)
# and Mojo::URL's ->query are not database handles, so they do not match.
my $SQL_CALL = qr/(?:\$\w*db|->db|\$dao)\s*->\s*(?:query|select|insert|update|delete)\s*\(/;

my %found;
for my $file ( path('lib')->list_tree->grep(qr/\.pm\z/)->each ) {
    my $rel = $file->to_rel('.')->to_string;
    next if $rel =~ m{\Alib/Registry/DAO(?:/|\.pm\z)};
    my $n = () = $file->slurp =~ /$SQL_CALL/g;
    $found{$rel} = $n if $n;
}

for my $rel ( sort keys %found ) {
    is $found{$rel}, $ALLOWED{$rel} // 0, "$rel: SQL calls outside the DAO match the allowlist";
}
for my $rel ( sort grep { !$found{$_} } keys %ALLOWED ) {
    fail "$rel: allowlisted but has no SQL calls left: drop it from the allowlist";
}

done_testing;
