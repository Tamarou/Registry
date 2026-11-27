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
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO;
use Registry::DAO::Offer;
use Registry::DAO::Entitlement;

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
    priceops-offer-policies
    priceops-entitlements
    priceops-entitlement-one-phase
    priceops-entitlement-units
    priceops-entitlement-lifecycle
    bootstrap-platform-offers
    priceops-occurrence-resources
    operator-right-entitlement
    self-offer-guard
    platform-entitlement-one-in-effect
    platform-entitlement-replaces-plan-link
    drop-pricing-relationships
    remove-free-platform-plan
    entitlement-uses
    holds-placed-at
    entitlement-refunds-per-entitlement
    retire-unpublished-platform-plans
    holds-lifetime
    retire-launch-rate-marker
    entitlement-stripe-move-adds-dispute-step
    drop-tenant-billing-columns
    workflow-roles-data
    attendance-check-drops-schedule-next
    offer-version-resource-set
    workflow-run-entitlements
    location-time-zone
    entitlement-terms-version
    solo-grants-workflow-set
    registry-run-right-at-import
    priceops-session-vocabulary
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
my @SLUGS = qw( order user group default table check select where having limit offset fetch union lateral window returning using references constraint primary foreign natural grant cross column inner unique leading trailing distinct collate both asymmetric only placing variadic );
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

# The loop above grades the revert as a whole-database diff.  This names the
# part of drop-pricing-relationships' revert that is easiest to get half right:
# a LIKE copy brings back the tables in a tenant schema but not their foreign
# keys, and nothing at all of the view.  Its own database, so it holds however
# far the loop above happens to leave its one.
# The loop above clones its tenant before the change deploys. A tenant cloned
# after it gets clone_schema's copies of registry's functions, which a revert
# naming only registry's would leave behind.
subtest 'location-time-zone revert leaves no zone guard in a tenant cloned after deploy' => sub {
    my $pg = Test::PostgreSQL->new or return fail $Test::PostgreSQL::errstr;
    my $to = $pg->uri;
    my $db = Mojo::Pg->new($to)->db;

    $sqitch->run( 'sqitch', 'deploy', '-t', $to, '--to', 'location-time-zone' );
    $db->query( 'INSERT INTO registry.tenants (name, slug) VALUES (?, ?)', 'Post clone', 'post_clone' );
    $db->query( 'SELECT registry.clone_schema(?)', 'post_clone' );
    $sqitch->run( 'sqitch', 'revert', '-t', $to, '--to', 'location-time-zone^', '-y' );

    is $db->query( q{
            SELECT string_agg(n.nspname || '.' || p.proname, ', ')
              FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE p.proname IN ('is_time_zone', 'locations_time_zone_known')
        } )->array->[0], undef, 'no zone guard function is left in any schema';
    is $db->query( q{SELECT count(*) FROM pg_trigger WHERE tgname = 'locations_time_zone_known'} )->array->[0],
        0, 'no zone guard trigger is left';
};

# clone_schema copies both of registry-run-right-at-import's functions into a
# tenant cloned after deploy; the revert must drop every copy.
subtest 'registry-run-right-at-import revert leaves no run-right function in a tenant cloned after deploy' => sub {
    my $pg = Test::PostgreSQL->new or return fail $Test::PostgreSQL::errstr;
    my $to = $pg->uri;
    my $db = Mojo::Pg->new($to)->db;

    $sqitch->run( 'sqitch', 'deploy', '-t', $to, '--to', 'registry-run-right-at-import' );
    $db->query( 'INSERT INTO registry.tenants (name, slug) VALUES (?, ?)', 'Post clone', 'post_clone' );
    $db->query( 'SELECT registry.clone_schema(?)', 'post_clone' );
    $sqitch->run( 'sqitch', 'revert', '-t', $to, '--to', 'registry-run-right-at-import^', '-y' );

    is $db->query( q{
            SELECT string_agg(n.nspname || '.' || p.proname, ', ')
              FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE p.proname IN ('registry_holds_run_right', 'workflow_registry_run_right')
        } )->array->[0], undef, 'no run-right function is left in any schema';
    is $db->query( q{SELECT count(*) FROM pg_trigger WHERE tgname = 'workflow_registry_run_right'} )->array->[0],
        0, 'no run-right trigger is left';
};

# The terms version guard lives in each tenant's own copy of entitlement_stamp,
# which clone_schema makes; the revert must put every copy back, or an update
# in a reverted tenant reads a column that is gone.
subtest 'entitlement-terms-version revert restores the guard in tenants cloned after deploy' => sub {
    my $pg = Test::PostgreSQL->new or return fail $Test::PostgreSQL::errstr;
    my $to = $pg->uri;
    my $db = Mojo::Pg->new($to)->db;
    my @tenants = qw( xregistry kidsregistry symmetric );

    $sqitch->run( 'sqitch', 'deploy', '-t', $to, '--to', 'entitlement-terms-version' );
    for my $slug (@tenants) {
        $db->query( 'INSERT INTO registry.tenants (name, slug) VALUES (?, ?)', "Terms $slug", $slug );
        $db->query( 'SELECT registry.clone_schema(?)', $slug );
    }

    my sub has ($slug) {
        return $db->query( q{
            SELECT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                            WHERE n.nspname = $1 AND p.proname = 'entitlement_stamp'
                              AND p.prosrc LIKE '%terms_version%') AS guard,
                   EXISTS (SELECT 1 FROM pg_constraint
                            WHERE conrelid = to_regclass(quote_ident($1) || '.entitlements')
                              AND conname = 'entitlements_terms_version_check') AS check,
                   EXISTS (SELECT 1 FROM information_schema.columns
                            WHERE table_schema = $1 AND table_name = 'entitlements'
                              AND column_name = 'terms_version') AS column
        }, $slug )->hash;
    }
    is_deeply has($_), { guard => 1, check => 1, column => 1 }, "$_ has the guard, the check and the column"
        for @tenants;

    # A real booking in the reserved-word tenant, made while the column exists.
    my $tenant = Registry::DAO->new( url => $to, schema => 'symmetric' )->db;
    my $class  = $tenant->insert( 'projects', { name => 'Class', slug => 'class' }, { returning => 'id' } )
        ->hash->{id};
    my $version = Registry::DAO::Offer->create( $tenant, { name => 'Wheel class' } )
        ->draft( $tenant, offer_terms( undef, class_project_id => $class ) )->publish($tenant);
    my $booking = Registry::DAO::Entitlement->create( $tenant, {
        holder_user_id   => $tenant->insert( 'users', { username => 'booker' }, { returning => 'id' } )->hash->{id},
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
        starts_at        => '2020-01-01T00:00:00Z',
        terms_version    => 'draft',
    } )->id;

    $sqitch->run( 'sqitch', 'revert', '-t', $to, '--to', 'entitlement-terms-version^', '-y' );

    is_deeply has($_), { guard => 0, check => 0, column => 0 }, "$_ has none of them after revert"
        for @tenants;
    # Through the tenant's own handle: its other entitlement triggers name
    # tables unqualified and resolve them by the tenant's search_path.
    is $tenant->query( "UPDATE entitlements SET in_effect = tstzrange('2020-01-01', '2099-01-01', '[)') WHERE id = ?",
            $booking )->rows, 1, 'an entitlement in a reverted tenant still updates';
    # Before $pg stops its server, or their cached statements warn as they die.
    $_->disconnect for $tenant, $db;
};

subtest 'revert restores pricing relationship view and keys' => sub {
    my $pg  = Test::PostgreSQL->new or return fail $Test::PostgreSQL::errstr;
    my $to  = $pg->uri;
    my $pgh = Mojo::Pg->new($to);
    my $db  = $pgh->db;

    $sqitch->run( 'sqitch', 'deploy', '-t', $to, '--to', 'drop-pricing-relationships^' );
    my @schemas = ( 'registry', 'returning', 'rt_pricing' );
    for my $slug ( @schemas[ 1 .. $#schemas ] ) {
        $db->query( 'INSERT INTO registry.tenants (name, slug) VALUES (?, ?)', "Pricing $slug", $slug );
        $db->query( 'SELECT registry.clone_schema(?)', $slug );
    }

    $sqitch->run( 'sqitch', 'deploy', '-t', $to, '--to', 'drop-pricing-relationships' );
    $sqitch->run( 'sqitch', 'revert', '-t', $to, '--to', 'drop-pricing-relationships^', '-y' );

    for my $schema (@schemas) {
        my $q = $db->query( 'SELECT quote_ident(?)', $schema )->array->[0];
        ok $db->query( q{SELECT to_regclass(?) IS NOT NULL AS ok},
                "$q.pricing_relationship_current_state" )->hash->{ok},
            "$schema has the pricing_relationship_current_state view again";
        is $db->query( q{
                SELECT pg_get_constraintdef(c.oid) AS def
                  FROM pg_constraint c
                 WHERE c.conrelid = to_regclass(?)
                   AND c.conname  = 'billing_periods_pricing_relationship_id_new_fkey'
            }, "$q.billing_periods" )->arrays->[0][0],
            "FOREIGN KEY (pricing_relationship_id) REFERENCES $q.pricing_relationships(id)",
            "$schema.billing_periods keys into its own pricing_relationships again";
    }
};

done_testing;
