#!/usr/bin/env perl
# ABOUTME: The payments-typed-obligation backfill is exercised against real pre-migration rows.
# ABOUTME: revert-round-trip.t deploys into an empty database, so it grades the schema only.
use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::PostgreSQL;
use Mojo::Pg;
use Mojo::JSON ();
use Test::Registry::DB ();

# The schema-dump harness next door deploys into a database with zero payment
# rows, so the backfill's `WHERE metadata ? 'refund_owed_cents'` matches nothing
# and verify's content assertions pass vacuously. Deleting the shared clamp, the
# tenant refund_increments write, and all four verify assertions left that suite
# green. This file seeds rows first.

my $CHANGE = 'payments-typed-obligation';

my $pgsql = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri   = $pgsql->uri;
my $db    = Mojo::Pg->new($uri)->db;

# Deploys are shelled out with output silenced for the same reason the verify
# helper below is: sqitch's progress lines parse as TAP.
sub deploy_to ($target) {
    system( "sqitch deploy -t '$uri' --to '$target' >/dev/null 2>&1" ) == 0
        or die "sqitch deploy --to $target failed\n";
}

deploy_to("$CHANGE^");

# A tenant schema, so the loop this branch has twice got wrong is exercised.
my $slug = "ob$$";
$db->query( 'INSERT INTO registry.tenants (name, slug) VALUES (?, ?)', "Ob $$", $slug );
$db->query( 'SELECT registry.clone_schema(?)', $slug );

# payments.user_id is NOT NULL, so the seeded rows need a real user. Created in
# registry and copied into the tenant schema, because clone_schema copies
# structure, not rows.
my $user_id = $db->query(
    'INSERT INTO registry.users (username) VALUES (?) RETURNING id',
    "ob_user_$$" )->hash->{id};
$db->query( sprintf( 'INSERT INTO %s.users (id, username) VALUES (?, ?)',
    $db->dbh->quote_identifier($slug) ), $user_id, "ob_user_$$" );

my $n = 0;
sub seed ($schema, $amount, $meta, $status = 'completed') {
    my $id = $db->query(
        sprintf( q{INSERT INTO %s.payments
                       (user_id, amount_cents, status, metadata)
                   VALUES (?, ?, ?, ?::jsonb) RETURNING id},
                 $db->dbh->quote_identifier($schema) ),
        $user_id, $amount, $status, $meta )->hash->{id};
    return $id;
}

sub row ($schema, $id) {
    $db->query( sprintf( 'SELECT * FROM %s.payments WHERE id = ?',
                         $db->dbh->quote_identifier($schema) ), $id )->expand->hash;
}

my %seeded;
for my $schema ( 'registry', $slug ) {
    $seeded{$schema} = {
        # Every quantity distinct, so no assertion can confuse two of them.
        plain     => seed( $schema, 20000, '{"refund_owed_cents":6600,"refund_owed_children":["kid-a"]}' ),
        # main's accumulator was unclamped: a debt bigger than the cart is real.
        over_cart => seed( $schema, 9000,  '{"refund_owed_cents":12000}' ),
        # owed and refunded each fit the cart, but their SUM does not.
        over_pair => seed( $schema, 9000,  '{"refund_owed_cents":7000,"refund_amount_cents":5500}' ),
        # percentage_discount is unbounded, so a negative share reached metadata.
        negative  => seed( $schema, 9000,  '{"refund_owed_cents":-500}' ),
        zero_cart => seed( $schema, 0,     '{"refund_owed_cents":100}' ),
        settled   => seed( $schema, 15000, '{"refund_amount_cents":4000}' ),
        # More recorded returned than was ever charged. Its own branch in the
        # flag CASE, and no fixture reached it.
        overpaid  => seed( $schema, 9000,  '{"refund_amount_cents":12000}' ),
        # The status the Leg 0 runbook told operators to write. The migration
        # normalises it; without a fixture, deleting that normalisation left the
        # suite green while payments_status_check aborted a real deploy.
        bricked   => seed( $schema, 11000, '{"refund_owed_cents":2200}', 'refund_failed' ),
        untouched => seed( $schema, 12000, '{"enrollment_items":[]}' ),
    };
}

deploy_to($CHANGE);

for my $schema ( 'registry', $slug ) {
    my $where = $schema eq 'registry' ? 'registry' : 'a tenant schema';
    my $s = $seeded{$schema};

    subtest "the backfill lands correctly in $where" => sub {
        my $r = row( $schema, $s->{plain} );
        is $r->{refund_owed_cents}, 6600, 'an ordinary debt carries across';
        is scalar @{ $r->{refund_increments} }, 1,
            'as an increment -- without one the debt is unrefundable by both callers';
        is $r->{refund_increments}[0]{cents}, 6600, 'for its own amount';
        is $r->{refund_increments}[0]{settled_at}, undef, 'unsettled, so the retry path takes it';
        is_deeply $r->{refund_increments}[0]{children}, ['kid-a'], 'naming its children';
        is $r->{refund_seq}, 1, 'and the counter matches';

        $r = row( $schema, $s->{over_cart} );
        is $r->{refund_owed_cents}, 9000, 'a debt bigger than the cart is clamped to it';
        is $r->{refund_increments}[0]{cents}, 9000,
            'and the increment carries the clamped figure, not the raw one';
        ok $r->{metadata}{refund_manual_review},
            'the clamped remainder is flagged rather than dropped in silence';

        $r = row( $schema, $s->{over_pair} );
        cmp_ok $r->{refund_owed_cents} + $r->{refunded_cents}, '<=', 9000,
            'owed and refunded are clamped as a PAIR -- each fits alone, the sum did not';
        is $r->{refunded_cents}, 5500, 'what went back is taken first';
        is $r->{refund_owed_cents}, 3500, 'and the debt gets what is left';

        $r = row( $schema, $s->{negative} );
        # The >= 0 assertion this replaced was decorative: the CHECK added in the
        # same transaction guarantees it, so any row that could fail it aborts
        # the deploy first and deploy_to's die is what actually grades it.
        is $r->{refund_owed_cents}, 0, 'a negative legacy value floors to zero';
        ok $r->{metadata}{refund_manual_review},
            'and is flagged -- the runtime path calls a nonsense share a human case';
        like $r->{metadata}{refund_manual_review}[0]{reason}, qr/negative/,
            'saying which nonsense it was';

        $r = row( $schema, $s->{overpaid} );
        is $r->{refunded_cents}, 9000, 'a refunded total above the charge is clamped to it';
        ok $r->{metadata}{refund_manual_review},
            'and flagged rather than silently truncated';
        is $r->{metadata}{refund_manual_review}[0]{metadata_refund_cents}, 12000,
            'naming the figure it clamped, which an operator can act on';

        $r = row( $schema, $s->{bricked} );
        is $r->{status}, 'refund_pending',
            'refund_failed is normalised before the status CHECK, not left to abort the deploy';
        is $r->{refund_owed_cents}, 2200, 'with its debt intact';

        $r = row( $schema, $s->{zero_cart} );
        is scalar @{ $r->{refund_increments} }, 0,
            'a zero-amount cart gets no zero-cent increment to POST to Stripe forever';

        $r = row( $schema, $s->{settled} );
        is $r->{refunded_cents}, 4000, 'a past refund carries across';
        is $r->{refund_owed_cents}, 0, 'owing nothing';

        $r = row( $schema, $s->{untouched} );
        is $r->{refund_owed_cents}, 0, 'a row with no obligation is left at the defaults';
        is scalar @{ $r->{refund_increments} }, 0, 'with no increments';
    };
}

subtest 'verify rejects a row the backfill must never produce' => sub {
    # verify already ran once, on deploy. These prove its content assertions are
    # not decorative: deleting all four left the schema-dump suite green,
    # because that suite deploys into a database with no payment rows.
    #
    # sqitch reports failure by exit status rather than by dying, so this shells
    # out and reads $?.
    # Output silenced: sqitch prints its own "ok" lines, which prove parses as
    # TAP and which then collide with this file's plan.
    my $verify = sub {
        my $rc = system( "sqitch verify -t '$uri' >/dev/null 2>&1" );
        return $rc;
    };

    is $verify->(), 0, 'verify passes on the backfilled database';

    for my $schema ( 'registry', $slug ) {
        my $q = $db->dbh->quote_identifier($schema);
        my $saved = $db->query( sprintf(
            'SELECT id, refund_increments FROM %s.payments WHERE refund_owed_cents > 0', $q )
        )->expand->hashes->to_array;
        ok scalar @$saved, "$schema has debt rows to corrupt";

        $db->query( sprintf(
            q{UPDATE %s.payments SET refund_increments = '[]'::jsonb
               WHERE refund_owed_cents > 0}, $q ) );
        isnt $verify->(), 0,
            "verify FAILS on debt with no increment to discharge it ($schema)";

        for my $r (@$saved) {
            $db->query( sprintf( 'UPDATE %s.payments SET refund_increments = ?::jsonb WHERE id = ?', $q ),
                Mojo::JSON::encode_json($r->{refund_increments}), $r->{id} );
        }
        is $verify->(), 0, "and passes again once restored ($schema)";

        # owed + refunded exceeding the charge is now refused by the constraint
        # itself, so it cannot be reached by an UPDATE at all. That is the
        # primary guard; verify's assertion is the backstop for a row that
        # somehow predates it.
        my $err = do {
            local $@;
            eval { $db->query( sprintf(
                q{UPDATE %s.payments SET refunded_cents = amount_cents
                   WHERE refund_owed_cents > 0}, $q ) ); 1 };
            $@;
        };
        like $err, qr/payments_refund_total_check/,
            "the sum constraint refuses owed + refunded above the charge ($schema)";

        # And verify still catches it if the constraint is not there to stop it.
        $db->query( sprintf(
            'ALTER TABLE %s.payments DROP CONSTRAINT payments_refund_total_check', $q ) );
        $db->query( sprintf(
            q{UPDATE %s.payments SET refunded_cents = amount_cents
               WHERE refund_owed_cents > 0}, $q ) );
        isnt $verify->(), 0,
            "verify FAILS when owed + refunded exceeds the charge ($schema)";

        $db->query( sprintf( 'UPDATE %s.payments SET refunded_cents = 0 WHERE refund_owed_cents > 0', $q ) );
        $db->query( sprintf(
            q{ALTER TABLE %s.payments ADD CONSTRAINT payments_refund_total_check
                   CHECK (refund_owed_cents + refunded_cents <= amount_cents)}, $q ) );
        is $verify->(), 0, "and passes again ($schema)";
    }
};

done_testing;
