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
    'lib/Registry/Command/workflow.pm'          => 1,
    'lib/Registry/Controller/AdminDashboard.pm' => 1,
    'lib/Registry/Controller/Messages.pm'       => 5,
    'lib/Registry/Controller/Waitlist.pm'       => 1,
    'lib/Registry/Controller/Webhooks.pm'       => 4,
    'lib/Registry/Controller/Workflows.pm'      => 7,
    'lib/Registry/Job/DomainVerification.pm'    => 2,
    'lib/Registry/Job/ProcessWaitlist.pm'       => 3,
    'lib/Registry/Job/SendNotifications.pm'     => 3,
);

# A database handle receiving an SQL method. A handle is a variable named for
# one ($db, $tdb, $dbh, $database, $conn..., or a Registry::DAO in $dao,
# $tenant_dao...) or a chain ending in ->db, ->dbh or ->dao, with or without
# an argument list (->db(), ->dao('registry')). The methods are Mojo::Pg's
# query/select/insert/update/delete, their _p forms, and raw DBI's do,
# prepare, selectall_* and selectrow_*. A DAO object's own ->update($db, ...)
# and Mojo::URL's ->query have no handle as receiver, so they do not match.
my $HANDLE   = qr/(?:\$\w*(?:db|dbh|dao|database|conn\w*)\b|->(?:db|dbh|dao)\b(?:\s*\([^()]*\))?)/;
my $METHOD   = qr/(?:(?:query|select|insert|update|delete)(?:_p)?|do|prepare|selectall_\w+|selectrow_\w+)/;
my $SQL_CALL = qr/$HANDLE\s*->\s*$METHOD\s*\(/;

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
