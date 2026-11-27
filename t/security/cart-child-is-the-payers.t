#!/usr/bin/env perl
# ABOUTME: Every session cart line's child is the signed-in payer's own, and a child is in a session at most once.
# ABOUTME: The refusal is asked again at checkout, so a line can never hold another family's child or a doubled seat.
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
use Registry::Terms;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent   = Test::Registry::Fixtures::create_user( $db, { username => 'payer_parent' } );
my $stranger = Test::Registry::Fixtures::create_user( $db, { username => 'payer_stranger' } );
sub child ( $family, $name ) {
    Registry::DAO::FamilyMember->create( $db, { family_id => $family->id, child_name => $name, birth_date => '2016-01-01' } );
}
my ( $kid, $sib, $theirs ) = ( child( $parent, 'Kid' ), child( $parent, 'Sib' ), child( $stranger, 'Theirs' ) );

my ( $s1, $s2 ) = map { scalar make_session( $db, days => [ map { days_from_now($_) } 30 .. 32 ] ) } 1, 2;
my %price = map { $_->id => session_offer( $db, $_ ) } $s1, $s2;

sub line ( $child, $session ) {
    return { family_member_id => $child->id, resource_id => $session->id,
        offer_version_id => $price{ $session->id }->id, payment_plan_id => 'pay' };
}
sub refusal (@lines) { Registry::DAO::WorkflowSteps::SessionCart->refusal( $db, { user_id => $parent->id }, \@lines ) }

subtest "the payer's own children may each take a session" => sub {
    is refusal( line( $kid, $s1 ), line( $sib, $s1 ), line( $kid, $s2 ) ), undef,
        'two children in one session, and one child in two';
};

subtest "another family's child is refused" => sub {
    like refusal( line( $theirs, $s1 ) ), qr/Choose one of your own children/, 'alone';
    like refusal( line( $kid, $s1 ), line( $theirs, $s2 ) ), qr/Choose one of your own children/,
        "or after a line of the payer's own";

    # Planted in the run's chosen children: the cart still refuses it.
    my ( $run, $step ) = cart_run( $dao, $parent->id, $kid->id, $theirs->id );
    my $result = add_cart_line( $db, $run, $step, family_member_id => $theirs->id, resource_id => $s1->id,
        choice => $price{ $s1->id }->id . '/pay' );
    like $result->{errors}[0], qr/Choose one of your own children/, 'refused at the step';
    ok !$run->data->{cart_lines}, 'and nothing reaches the cart';
    ok !( grep { $_->{id} eq $theirs->id } $step->prepare_template_data( $db, $run )->{children}->@* ),
        'nor is the child shown';
};

subtest 'a cart with no signed-in payer is refused' => sub {
    like Registry::DAO::WorkflowSteps::SessionCart->refusal( $db, {}, [ line( $kid, $s1 ) ] ), qr/Sign in/, 'refused';
};

subtest 'a child is in a session at most once' => sub {
    like refusal( line( $kid, $s1 ), line( $kid, $s1 ) ), qr/only once/, 'a second line for the same seat is refused';
};

subtest 'checkout asks again' => sub {
    my $leaver = child( $parent, 'Leaver' );
    my ( $run, $step ) = cart_run( $dao, $parent->id, $leaver->id );
    ok !add_cart_line( $db, $run, $step, family_member_id => $leaver->id, resource_id => $s1->id,
        choice => $price{ $s1->id }->id . '/pay' )->{errors}, 'a line is added';
    # The child moves to another family after the line was added.
    $db->update( 'family_members', { family_id => $stranger->id }, { id => $leaver->id } );
    my $result = $run->process( $db, $step, { action => 'checkout', agree_to_terms => 1,
        terms_version_shown => Registry::Terms::VERSION } );
    like $result->{errors}[0], qr/Choose one of your own children/, 'checkout refuses the line';
    ok !exists $run->data->{agreed_terms_version}, 'and records no agreement';
};

done_testing;
