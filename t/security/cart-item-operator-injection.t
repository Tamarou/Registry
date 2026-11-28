#!/usr/bin/env perl
# ABOUTME: Proves a hashref in a session cart line's child, session or price, or in the run's payer, cannot reach a WHERE clause.
# ABOUTME: SQL::Abstract renders a hashref as an OPERATOR, so one would answer about a different family's row.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( days_from_now );
use Test::Registry::Sessions qw( make_session session_offer cart_run add_cart_line );
use Registry::DAO::FamilyMember;
use Registry::DAO::WorkflowSteps::SessionCart;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = Test::Registry::Fixtures::create_user( $db, { username => 'cart_parent' } );
my $other  = Test::Registry::Fixtures::create_user( $db, { username => 'cart_other' } );
my ( $mine, $theirs ) = map {
    Registry::DAO::FamilyMember->create( $db, { family_id => $_->[0]->id, child_name => $_->[1], birth_date => '2016-01-01' } )
} [ $parent, 'Mine' ], [ $other, 'Theirs' ];

my $session = make_session( $db, days => [ map { days_from_now($_) } 30 .. 32 ] );
my $price   = session_offer( $db, $session );
my %line    = ( family_member_id => $mine->id, resource_id => $session->id, choice => $price->id . '/pay' );

# The shape a bracketed form parameter expands to: field[!=]=<id>.
for my $field (qw( family_member_id resource_id choice )) {
    subtest "an operator in $field is refused" => sub {
        my ( $run, $step ) = cart_run( $dao, $parent->id, $mine->id );
        my $result = add_cart_line( $db, $run, $step, %line, $field => { '!=' => $theirs->id } );
        ok $result->{errors}, 'it is refused rather than answered';
        ok !$run->data->{cart_lines}, 'and nothing reaches the cart';
    };
}

subtest 'an operator as the payer is refused, and lists no family' => sub {
    my $why = Registry::DAO::WorkflowSteps::SessionCart->refusal( $db,
        { user_id => { '!=' => $parent->id } },
        [ { family_member_id => $theirs->id, resource_id => $session->id,
            offer_version_id => $price->id, payment_plan_id => 'pay' } ] );
    like $why, qr/Sign in/, 'refused: "not this parent" is no one';
};

subtest 'a plain id still works' => sub {
    my ( $run, $step ) = cart_run( $dao, $parent->id, $mine->id );
    ok !add_cart_line( $db, $run, $step, %line )->{errors}, 'the guard refuses structure, not ids';
    is scalar $run->data->{cart_lines}->@*, 1, 'the line is in the cart';
};

done_testing;
