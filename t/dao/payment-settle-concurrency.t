#!/usr/bin/env perl
# ABOUTME: Two overlapping settles of one increment record the money once, not twice.
# ABOUTME: A materialised CTE goes stale under EvalPlanQual where a correlated subquery does not.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Mojo::Pg;
use Registry::DAO::Payment;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_settle_concurrency';

my $test_db = Test::Registry::DB->new;
my $uri     = $test_db->uri;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = $dao->create(User => {
    username => 'sc_parent', name => 'SC Parent', user_type => 'parent',
    email => 'sc@test.local' });

# The defect this grades: settle_refund_increment once took its amount from a
# WITH CTE. A CTE is materialised from the statement's snapshot, and under READ
# COMMITTED a blocked UPDATE re-evaluates CORRELATED subqueries against the
# updated row via EvalPlanQual but NOT a CTE. So the jsonb rewrite correctly
# no-opped on the second settle while the arithmetic applied a stale amount:
# 3000 reached Stripe, the row recorded 6000 returned. Every reference is
# correlated now, and the guard is an EXISTS in the WHERE.
#
# Two real connections and a fork, because a single connection cannot produce
# the interleaving -- the second statement would see the first's committed row
# rather than blocking on its lock.
subtest 'a second settle of the same increment records nothing' => sub {
    my $p = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => 20000, status => 'pending',
        metadata => { enrollment_items => [], tenant_slug => undef } });
    $p->record_capacity_obligation( $db, 3000, ['kid-a'] );
    my $id = $p->id;

    pipe( my $child_reads, my $parent_writes ) or die "pipe: $!";
    my $pid = fork();
    defined $pid or die "fork: $!";

    unless ($pid) {
        # Child: wait for A to hold the lock, then settle the same seq. It
        # blocks on A's row lock and re-plans when A commits.
        close $parent_writes;
        readline $child_reads;
        # The Mojo::Pg must outlive the handle -- ->db holds only a weak
        # reference, so Mojo::Pg->new(...)->db dies on the next query.
        my $cpg = Mojo::Pg->new($uri)->search_path(['registry', 'public']);
        my $cdb = $cpg->db;
        my $cp  = Registry::DAO::Payment->find( $cdb, { id => $id } );
        $cp->settle_refund_increment( $cdb, 1, { id => 're_B' } );
        exit 0;
    }

    close $child_reads;
    my $apg = Mojo::Pg->new($uri)->search_path(['registry', 'public']);
    my $adb = $apg->db;
    my $tx  = $adb->begin;
    Registry::DAO::Payment->find( $adb, { id => $id } )
        ->settle_refund_increment( $adb, 1, { id => 're_A' } );
    print $parent_writes "go\n";
    $parent_writes->flush;
    sleep 1;              # let the child reach the lock and block on it
    $tx->commit;
    waitpid $pid, 0;

    my $row = $db->select('payments', '*', { id => $id })->expand->hash;
    is $row->{refunded_cents}, 3000,
        'exactly the 3000 that reached Stripe is recorded as returned, once';
    is $row->{refund_owed_cents}, 0, 'and the debt is discharged once';
    is $row->{refund_increments}[0]{refund_id}, 're_A',
        'the first settle owns the increment; the second overwrites nothing';
};

done_testing;
