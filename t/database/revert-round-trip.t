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

# Changes graded here.  A leg that ships a migration appends its change name in
# the same commit; that is the whole registration mechanism.  Pinning '@HEAD^'
# instead would grade only whichever change happens to be last, and Task 7's
# data-only change -- which round-trips trivially under a schema dump -- would
# then mask Task 6's hundred-line revert.
#
# ASCENDING IN sql/sqitch.plan ORDER, and that is load-bearing rather than
# tidy.  Each iteration deploys '--to $change^' and leaves the database at that
# parent, so the next iteration's '--to' must be a forward move.  A list out of
# plan order asks sqitch to deploy backwards and the run stops meaning what the
# assertions claim.  payments-amount-cents is sqitch.plan:65, refund is :67.
#
# Both are real subjects rather than placeholders.  payments-amount-cents sits
# on the money tables this milestone keeps and its revert is broken three ways
# (see the task notes).  refund-amounts-cents re-adds two dropped columns and so
# exercises the attnum tolerance the sorted comparison exists for.
my @CHANGES = qw(
    payments-amount-cents
    refund-amounts-cents
    drop-installment-schedules
    webhook-events-processed-at
    payments-typed-obligation
    enrollment-reenrol-after-drop
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
#
# The trailing comma has to come off for that to hold.  A column line's comma
# means "not the last column in this table", so a re-added column landing at the
# end gives the previous last column a comma it did not have -- attnum drift
# leaking through the sort as a pair of phantom differences.  Strip the optional
# comma and the newline together so both forms normalize to the same string;
# stripping the comma alone would take the newline with it on comma lines only
# and reintroduce the same phantom from the other side.
sub dump_schema () {
    my @lines = qx{$pg_dump --schema-only --no-owner --no-privileges --restrict-key=rt --exclude-schema=sqitch '$uri'};
    $? == 0 or die 'pg_dump failed';
    # Drop comment lines and blanks: pg_dump emits version banners that vary.
    return [ sort map { s/,?\s*$//r } grep { !/^--/ && /\S/ } @lines ];
}

my $sqitch = App::Sqitch->new();

# One tenant schema per change, so entries after the first do not collide
# on tenants_slug_key (sql/test-schema.sql:3269-3273).  Earlier iterations'
# schemas stay behind and appear in both dumps, which is harmless -- the
# comparison is before-vs-after, not against a fixture.
#
# The slugs are SQL reserved words on purpose.  A slug like 'rt_123_0' needs no
# quoting anywhere, so a migration that interpolates the schema name with %s
# where it should use %I round-trips clean and the harness grades nothing about
# quoting.  Reserved words are the only quoting-hostile slugs clone_schema
# survives: fix-clone-schema-identifier-quoting.sql:314 runs
# PERFORM set_config('search_path', dest_schema, true) on the UNQUOTED name and
# then strips the 'registry.' prefix from FK, function, trigger and view definitions
# (:386,406,455,468) so that search_path re-resolves them.  A reserved word
# case-folds to itself, so the fold is the identity and only DDL syntax needs
# quoting, which quote_ident supplies.  A mixed-case slug does not fold to
# itself, and clone_schema dies partway with
#   relation "RT_Mixed_1234.pricing_relationship_events_sequence_number_seq"
#   does not exist
# Do not "improve" this list with mixed case or hyphens.  Both were tried
# against live Postgres; both break the harness rather than the migrations.
# 'default' sits fourth rather than last so that the newest change exercises the
# newest slug: a slug appended to the end is not reached until a later leg adds
# the change that pairs with it, and an unverified slug fails far from the commit
# that introduced it.  Verified against live Postgres -- clone_schema('default')
# succeeds and pg_dump renders it "default".enrollments, so the quoted assertion
# below matches.
my @SLUGS = qw( order user group default table check );
@CHANGES <= @SLUGS
    or die sprintf 'revert-round-trip needs one reserved-word slug per change: %d changes, %d slugs',
        scalar @CHANGES, scalar @SLUGS;

my $n = 0;

for my $change (@CHANGES) {
    my $slug = $SLUGS[ $n++ ];

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

        # Quoted, because pg_dump renders a reserved-word schema as
        # "order".enrollments -- an unquoted /\Qorder\E\./ matches nothing and
        # this assertion would fail on every run.  Verified by running both
        # forms against one dump in the same process.
        my $before = dump_schema();
        ok scalar( grep { /"\Q$slug\E"\./ } @$before ),
            qq{dump at $change^ includes the cloned tenant schema "$slug"};

        $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', $change );
        $sqitch->run( 'sqitch', 'revert', '-t', $uri, '--to', "$change^", '-y' );

        is_deeply dump_schema(), $before,
            "deploying $change and reverting it restores the schema exactly";

        # Leave the database at the parent so the next iteration's deploy --to
        # is a forward move rather than a no-op.
    };
}

done_testing;
