#!/usr/bin/env perl
# ABOUTME: sql/test-schema.sql must match what sql/deploy/ actually produces.
# ABOUTME: Every bare `prove` run grades the committed dump, not the migrations.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::PostgreSQL;
use Test::Registry::DB ();
use App::Sqitch;
use File::Temp qw(tempdir);
use File::Spec;
use Mojo::Pg;

# The dump is a generated artefact that goes stale in silence. `make test`
# regenerates it through its sql/deploy/*.sql dependency, but CI runs a bare
# `carton exec prove -lr t/` and every documented single-file invocation is bare
# too -- so the schema under test is whatever was last committed. That is not
# hypothetical: this file exists because the committed dump once carried
# `WHERE (status <> 'cancelled')` for several commits after the deploy script
# had moved to `IS DISTINCT FROM`, and was missing a table, while the suite ran
# green against it.
#
# BOTH sides are re-dumped here, by the same binary against the same server, in
# this run. Comparing a fresh dump against the committed FILE looks simpler and
# is wrong: pg_dump's output is version-specific, so a dump written on 18.4
# begins `SET transaction_timeout = 0`, a parameter that does not exist on 14,
# and the comparison diverges at line 4 of the preamble on a schema that is
# perfectly current. That is not hypothetical either -- it is how this file
# first failed in CI, which runs postgres:14 while this workstation runs 18.4.
# Round-tripping the committed dump through a database cancels every
# version-specific rendering difference and leaves only real divergence.
#
# The obvious gate -- `make test-schema && git diff --exit-code` -- cannot work,
# because generate_dump dumps seed rows whose UUIDs and timestamps are fresh on
# every run. So compare the DDL only, plus a stable projection of the money seed.

# Borrowed, not copied. This file must dump with whatever `make test-schema`
# writes with; a second search order that drifts from that one makes every
# comparison below a permanent false failure on the host where they disagree.
sub pg_tool ($tool) { Test::Registry::DB::_find_pg_tool($tool) }

sub ddl_only ($path) {
    open my $fh, '<', $path or die "open $path: $!";
    my @ddl;
    my $in_copy = 0;
    while ( my $line = <$fh> ) {
        # COPY payloads carry gen_random_uuid()/now() values that differ on
        # every regeneration. The DDL is what this comparison is about; the
        # money seed is graded separately below.
        if ($in_copy) { $in_copy = 0 if $line =~ /\A\\\.\s*\z/; next }
        $in_copy = 1, next if $line =~ /\ACOPY .* FROM stdin;/;

        # Also dropped here: \restrict carries a per-dump random nonce, so the
        # two sides never match on it, and transaction_timeout is absent from
        # the committed artefact but present in a fresh dump.
        next if Test::Registry::DB::is_nonportable_line($line);

        # Column 0 for comments, for the same reason the portability filter is
        # anchored: pg_dump's own annotations are unindented, while plpgsql
        # bodies carry indented comment lines that are content. Stripping those
        # from both sides makes drift on them invisible here.
        next if $line =~ /\A--/;
        # Blank lines stay unanchored -- a blank line is blank wherever it sits,
        # and pg_dump's spacing between statements is not drift worth grading.
        next if $line =~ /\A\s*\z/;
        push @ddl, $line;
    }
    return \@ddl;
}

my $committed = File::Spec->catfile(qw(sql test-schema.sql));
ok -s $committed, 'the committed dump exists and is not empty' or do { done_testing; exit };

my $pg_dump = pg_tool('pg_dump');
my $psql    = pg_tool('psql');
my $tmp     = tempdir( CLEANUP => 1 );

sub dump_to ($uri, $name) {
    my $out = File::Spec->catfile( $tmp, $name );
    system("$pg_dump '$uri' > '$out' 2>/dev/null") == 0 or die "pg_dump failed";
    return $out;
}

my $load_seq = 0;

sub load_into ($uri, $file) {
    # ON_ERROR_STOP, or the `or die` below is decoration: psql exits 0 even when
    # every statement in the file failed. Without it a dump that will not load
    # shows up as the DDL comparison failing with "run `make test-schema`" --
    # the wrong instruction for the wrong cause, on the one test whose job is to
    # diagnose exactly this artefact.
    #
    # Which then requires dropping pg_dump's preamble SETs. They are session
    # settings that cannot affect the resulting schema, and they are the one
    # part of a dump that is not portable across majors: a dump written on 18.4
    # opens with `SET transaction_timeout = 0`, and PostgreSQL 14 -- which CI
    # runs -- rejects it as an unrecognized parameter. Measured against 14, that
    # line is the ONLY statement in the committed dump that fails; every piece
    # of DDL loads. Both sides get their preamble from the re-dump anyway, so
    # discarding it here costs the comparison nothing.
    my $portable = File::Spec->catfile( $tmp, 'portable-' . $load_seq++ . '.sql' );
    open my $in,  '<', $file     or die "open $file: $!";
    open my $out, '>', $portable or die "open $portable: $!";
    while ( my $line = <$in> ) {
        next if Test::Registry::DB::is_nonportable_line($line);
        print {$out} $line;
    }
    close $out;

    system( "$psql -v ON_ERROR_STOP=1 '$uri' < '$portable' >/dev/null" ) == 0
        or die "loading $file failed (see stderr above)";
}

# Both sides are compared after the SAME number of parse cycles, because
# Postgres re-renders some expressions when it re-reads them. A CHECK written
# once as
#     ANY ((ARRAY['pending'::character varying, ...])::text[])
# comes back as
#     ANY (ARRAY[('pending'::character varying)::text, ...])
# after a load-and-dump. Both spellings mean the same thing, so a side that has
# been through one more round trip than the other diverges on a schema that is
# perfectly current.
#
# Side A: the migrations, dumped, reloaded, dumped again.
my $migrated = Test::PostgreSQL->new;
App::Sqitch->new->run( 'sqitch', 'deploy', '-t', $migrated->uri );

my $migrated_rt = Test::PostgreSQL->new;
load_into( $migrated_rt->uri, dump_to( $migrated->uri, 'from-migrations.sql' ) );

# Side B: the committed dump -- itself already a first-generation dump -- loaded
# and dumped once, which is the same one cycle side A just took.
my $restored = Test::PostgreSQL->new;
load_into( $restored->uri, $committed );

my $fresh = ddl_only( dump_to( $migrated_rt->uri, 'migrations-rt.sql' ) );
my $have  = ddl_only( dump_to( $restored->uri,    'committed-rt.sql' ) );

is scalar @$have, scalar @$fresh,
    'the committed dump has as many DDL lines as a fresh deploy produces';

my $first_diff;
for my $i ( 0 .. ( @$fresh > @$have ? $#$fresh : $#$have ) ) {
    my ( $a, $b ) = ( $fresh->[$i], $have->[$i] );
    next if defined $a && defined $b && $a eq $b;
    $first_diff = $i;
    last;
}

ok !defined $first_diff,
    'sql/test-schema.sql is current with sql/deploy/ -- run `make test-schema`'
    or diag sprintf
        "first divergence at DDL line %d\n  deploy produces: %s  committed has:  %s",
        $first_diff + 1,
        $fresh->[$first_diff] // "(nothing -- committed dump is longer)\n",
        $have->[$first_diff]  // "(nothing -- committed dump is shorter)\n";

# DDL is not the whole artefact. The seeded pricing plans live in a COPY block,
# which ddl_only discards by design -- and the platform's revenue-share rate is
# one of those rows. Registry's rule is that rate assertions read the DB and
# never a literal, so t/priceops/revenue-share.t reads THIS FILE. A migration
# that moves the launch rate without `make test-schema` therefore leaves both
# that test and the DDL comparison above green while the deployed rate differs:
#
#     migration says 0.025, committed dump says 0.02
#     staleness detector: PASS      rate test: PASS
#
# Measured, in that direction. So compare the money seed too -- a narrow, stable
# projection with no ids and no timestamps, which is exactly the subset the COPY
# skip exists to avoid.
subtest 'the seeded money configuration matches what the migrations produce' => sub {
    my $projection = q{
        SELECT plan_scope, plan_name, plan_type, pricing_model_type, amount_cents,
               pricing_configuration->>'description'             AS blurb,
               metadata->>'coming_soon'                          AS coming_soon,
               metadata->>'launch_rate'                          AS launch_rate,
               metadata->>'display_order'                        AS display_order,
               pricing_configuration->>'percentage'             AS pct,
               pricing_configuration->>'monthly_base'           AS base,
               pricing_configuration->>'refund_application_fee' AS refund_fee
          FROM registry.pricing_plans
         ORDER BY plan_scope, plan_name
    };

    my $from_migrations =
        Mojo::Pg->new( $migrated->uri )->db->query($projection)->hashes->to_array;
    my $from_dump =
        Mojo::Pg->new( $restored->uri )->db->query($projection)->hashes->to_array;

    ok scalar @$from_migrations, 'the migrations seed at least one pricing plan'
        or return;
    is_deeply $from_dump, $from_migrations,
        'the committed dump seeds the same plans, rates and amounts as sql/deploy/'
        or diag 'run `make test-schema` -- a rate assertion that reads the DB is '
              . 'reading this dump, not the migrations';
};


# The plans projection above answers "what rates exist". It does not answer
# "which of them is on offer", and that is a separate row in a separate table:
# registry.pricing_relationships carries the status, and two whole migrations
# exist only to move rows in it -- suspend-rateless-tenant-plans and
# retire-registry-plus-plan. A dump that still shows a retired plan as active
# leaves the plans comparison green, because the plan itself did not change.
#
# Measured in that direction: flipping the suspend-rateless-tenant-plans row
# from 'suspended' back to 'active' in the committed dump left both this file
# and t/priceops/revenue-share.t passing, with the suite running against a
# rateless plan the migrations had retired.
#
# Same stability property as the plans projection: no ids, no timestamps.
subtest 'the seeded plan relationships match what the migrations produce' => sub {
    my $projection = q{
        SELECT r.status, p.plan_scope, p.plan_name,
               -- The SNAPSHOT, not the joined name. p.plan_name comes through
               -- the join and is current by construction, so comparing it
               -- grades nothing about this row. The denormalised copy is the
               -- one that goes stale when a plan is renamed, and it did.
               r.metadata->>'plan_name'              AS name_snapshot,
               r.metadata->>'created_by_migration'   AS created_by,
               r.metadata->>'suspended_by_migration' AS suspended_by
          FROM registry.pricing_relationships r
          JOIN registry.pricing_plans p ON p.id = r.pricing_plan_id
         ORDER BY p.plan_name, r.status
    };

    my $from_migrations =
        Mojo::Pg->new( $migrated->uri )->db->query($projection)->hashes->to_array;
    my $from_dump =
        Mojo::Pg->new( $restored->uri )->db->query($projection)->hashes->to_array;

    ok scalar @$from_migrations, 'the migrations seed at least one relationship'
        or return;
    is_deeply $from_dump, $from_migrations,
        'the committed dump offers the same plans as sql/deploy/'
        or diag 'run `make test-schema` -- a plan retired by a migration is '
              . 'still on offer in this dump';
};


done_testing;
