#!/usr/bin/env perl
# ABOUTME: Proves each listed sqitch change reverts cleanly: deploy to its parent, dump, deploy it, revert it, dump, diff.
# ABOUTME: A revert script that fails to restore the schema fails here instead of in production.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use App::Sqitch;
use Test::PostgreSQL;
use Mojo::Pg;
use Test::Registry::DB ();

# Changes graded here, in plan order.  A leg that ships a migration appends its
# change name in the same commit; that is the whole registration mechanism.
# Pinning '@HEAD^' instead would grade only whichever change happens to be last,
# and Task 7's data-only change -- which round-trips trivially under a schema
# dump -- would then mask Task 6's hundred-line revert.
#
# refund-amounts-cents is the plan tip as this file is written.  It is a real
# subject rather than a placeholder: its revert re-adds two dropped columns and
# so exercises the attnum tolerance the sorted comparison exists for.
my @CHANGES = qw(
    refund-amounts-cents
    drop-installment-schedules
);

my $pgsql = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri   = $pgsql->uri;

my $pg_dump = Test::Registry::DB::_find_pg_tool('pg_dump');

# --restrict-key pins the random \restrict token pg_dump 18 emits per
# invocation; it is not a comment, so the filter below would miss it.
# --exclude-schema=sqitch drops the deploy-history tables, which legitimately
# differ between the two dumps.
#
# The result is sorted: pg_dump prints columns in attnum order and a revert that
# re-adds a dropped column cannot put it back in its original position.  Sorting
# compares the multiset of schema statements, so a missing or altered column,
# index, constraint, trigger or comment still fails and attnum drift does not.
sub dump_schema () {
    my @lines = qx{$pg_dump --schema-only --no-owner --no-privileges --restrict-key=rt --exclude-schema=sqitch '$uri'};
    $? == 0 or die 'pg_dump failed';
    # Drop comment lines and blanks: pg_dump emits version banners that vary.
    return [ sort grep { !/^--/ && /\S/ } @lines ];
}

my $sqitch = App::Sqitch->new();
my $n      = 0;

for my $change (@CHANGES) {
    # One tenant schema per change, so a second entry on @CHANGES does not
    # collide on tenants_slug_key (sql/test-schema.sql:3269-3273).  Earlier
    # iterations' schemas stay behind and appear in both dumps, which is
    # harmless -- the comparison is before-vs-after, not against a fixture.
    my $slug = sprintf 'rt_%d_%d', $$, $n++;

    subtest "$change reverts cleanly" => sub {
        # 'NAME^' resolves to the change before NAME.  Legal because the caret
        # follows a letter; '@^' would not be (see the header note).
        $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', "$change^" );

        # The tenant loops in these migrations are the half most likely to be
        # wrong, and a migration-only database has no tenant schema at all --
        # only 'registry' and 'sqitch'.  clone_schema is what provisioning
        # actually uses, so it is what the revert has to satisfy.  It copies
        # triggers as a separate step that LIKE ... INCLUDING ALL does not.
        #
        # Call it schema-qualified: the function lives in 'registry'
        # (fix-clone-schema-identifier-quoting.sql:7 sets the search_path for
        # its own creation), and a bare Mojo::Pg connection searches
        # '"$user", public', where it is not found.
        my $db = Mojo::Pg->new($uri)->db;
        $db->query('INSERT INTO registry.tenants (name, slug) VALUES (?, ?)',
            "Round Trip $n", $slug);
        $db->query('SELECT registry.clone_schema(?)', $slug);

        my $before = dump_schema();
        ok scalar( grep { /\Q$slug\E\./ } @$before ),
            "dump at $change^ includes the cloned tenant schema $slug";

        $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', $change );
        $sqitch->run( 'sqitch', 'revert', '-t', $uri, '--to', "$change^", '-y' );

        is_deeply dump_schema(), $before,
            "deploying $change and reverting it restores the schema exactly";

        # Leave the database at the parent so the next iteration's deploy --to
        # is a forward move rather than a no-op.
    };
}

done_testing;
