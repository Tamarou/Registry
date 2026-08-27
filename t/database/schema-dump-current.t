#!/usr/bin/env perl
# ABOUTME: sql/test-schema.sql must match what sql/deploy/ actually produces.
# ABOUTME: Every bare `prove` run grades the committed dump, not the migrations.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::PostgreSQL;
use App::Sqitch;
use File::Temp qw(tempdir);
use File::Spec;

# The dump is a generated artefact that goes stale in silence. `make test`
# regenerates it through its sql/deploy/*.sql dependency, but CI runs a bare
# `carton exec prove -lr t/` and every documented single-file invocation is bare
# too -- so the schema under test is whatever was last committed. That is not
# hypothetical: this file exists because the committed dump once carried
# `WHERE (status <> 'cancelled')` for several commits after the deploy script
# had moved to `IS DISTINCT FROM`, and was missing a table, while the suite ran
# green against it.
#
# The obvious gate -- `make test-schema && git diff --exit-code` -- cannot work,
# because generate_dump dumps seed rows whose UUIDs and timestamps are fresh on
# every run. So compare the DDL only.

sub ddl_only ($path) {
    open my $fh, '<', $path or die "open $path: $!";
    my @ddl;
    my $in_copy = 0;
    while ( my $line = <$fh> ) {
        # COPY payloads carry gen_random_uuid()/now() values that differ on
        # every regeneration. The DDL is what this test is about.
        if ($in_copy) { $in_copy = 0 if $line =~ /\A\\\.\s*\z/; next }
        $in_copy = 1, next if $line =~ /\ACOPY .* FROM stdin;/;

        next if $line =~ /\A\s*--/;              # comments, incl. the pg_dump banner
        next if $line =~ /\A\\(un)?restrict\b/;  # per-dump nonce (CVE-2025-8714)
        next if $line =~ /\A\s*\z/;
        push @ddl, $line;
    }
    return \@ddl;
}

my $committed = File::Spec->catfile(qw(sql test-schema.sql));
ok -s $committed, 'the committed dump exists and is not empty' or done_testing, exit;

my $pg  = Test::PostgreSQL->new;
my $out = File::Spec->catfile( tempdir( CLEANUP => 1 ), 'fresh.sql' );

App::Sqitch->new->run( 'sqitch', 'deploy', '-t', $pg->uri );

my ($pg_dump) = grep { -x } (
    '/usr/bin/pg_dump',
    ( map { "/usr/lib/postgresql/$_/bin/pg_dump" } 18, 17, 16, 15, 14 ),
);
$pg_dump //= 'pg_dump';
system("$pg_dump '" . $pg->uri . "' > '$out' 2>/dev/null") == 0
    or die 'pg_dump failed';

my $fresh = ddl_only($out);
my $have  = ddl_only($committed);

is scalar @$fresh, scalar @$have,
    'the committed dump has as many DDL lines as a fresh deploy produces';

my $first_diff;
for my $i ( 0 .. $#{ [ @$fresh > @$have ? @$fresh : @$have ] } ) {
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

done_testing;
