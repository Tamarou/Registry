#!/usr/bin/env perl
# ABOUTME: Monthly Revenue reports what the tenant kept, net of refunds owed and sent.
# ABOUTME: A partial refund must reduce the tile by its own share, not remove the cart.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::AdminDashboard;
use Registry::DAO::User;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

Test::Registry::Fixtures::create_tenant( $dao->db, {
    name => 'Revenue Tenant', slug => 'test_revenue',
} );
$dao->db->query( 'SELECT clone_schema(?)', 'test_revenue' );
$dao = Registry::DAO->new( url => $test_db->uri, schema => 'test_revenue' );
my $db = $dao->db;

my $parent = Registry::DAO::User->create( $db, {
    email => 'p@revenue.test', username => 'p_revenue',
    password => 'password123', name => 'Parent', user_type => 'parent',
} );

# Written directly: the point is what the tile makes of a row in each state,
# not how the row got there.
sub a_payment ( $status, $amount_cents, %rest ) {
    $db->insert( 'payments', {
        user_id           => $parent->id,
        amount_cents      => $amount_cents,
        status            => $status,
        refund_owed_cents => $rest{owed}     // 0,
        refunded_cents    => $rest{refunded} // 0,
        metadata          => { -json => {} },
    } );
}

sub tile { Registry::DAO::AdminDashboard->get_overview_stats($db)->{monthly_revenue} }

subtest 'a completed cart counts in full' => sub {
    a_payment( 'completed', 5000 );
    is tile(), '50.00', 'the whole charge';
};

# A capacity demotion or a duplicate seat sets the cart to refund_pending for a
# PARTIAL debt. Filtering the tile to status = 'completed' dropped the entire
# cart, so a $100 debt against a $300 cart cost the tile $300.
subtest 'a partial debt costs the tile the debt, not the cart' => sub {
    a_payment( 'refund_pending', 30000, owed => 10000 );
    is tile(), '250.00', '$50 + ($300 - $100 owed)';
};

# Settled partial refunds were excluded the same way.
subtest 'a settled partial refund costs the tile what went back' => sub {
    a_payment( 'partially_refunded', 20000, refunded => 5000 );
    is tile(), '400.00', 'plus ($200 - $50 refunded)';
};

subtest 'a fully refunded cart contributes nothing, and does not go negative' => sub {
    a_payment( 'refunded', 10000, refunded => 10000 );
    is tile(), '400.00', 'unchanged';
};

# Money that was never captured is not revenue.
subtest 'uncaptured payments are not counted' => sub {
    a_payment( $_, 99999 ) for qw( pending processing failed );
    is tile(), '400.00', 'pending, processing and failed are all excluded';
};

done_testing;
