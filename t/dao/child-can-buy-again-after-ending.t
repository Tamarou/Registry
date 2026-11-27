#!/usr/bin/env perl
# ABOUTME: A child whose entitlement to a session ended (refunded) can be put in that session's cart again.
# ABOUTME: The ended entitlement frees its seat at once, so the cart offers the session and takes the line.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( days_from_now );
use Test::Registry::Sessions qw( make_session session_offer cart_run add_cart_line );
use Registry::DAO::Entitlement;
use Registry::DAO::FamilyMember;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = Test::Registry::Fixtures::create_user( $db, { username => 'again_parent' } );
my $kid    = Registry::DAO::FamilyMember->create( $db,
    { family_id => $parent->id, child_name => 'Again', birth_date => '2016-01-01' } );

# One seat, so the ended entitlement's seat is the only one there is.
my $session = make_session( $db, days => [ map { days_from_now($_) } 30 .. 32 ], capacity => 1 );
my $price   = session_offer( $db, $session );

my $held = Registry::DAO::Entitlement->grant( $db, {
    holder_family_member_id => $kid->id, payer_user_id => $parent->id,
    offer_version_id => $price->id, payment_plan_id => 'pay',
    starts_at => '2026-01-01T00:00:00Z', resource_id => $session->id, units => 1,
} );

sub add () {
    my ( $run, $step ) = cart_run( $dao, $parent->id, $kid->id );
    my ($shown) = $step->prepare_template_data( $db, $run )->{children}->@*;
    ok !!$shown->{sessions}[0]{full} == !!$held->is_in_effect($db), 'the cart shows the session full only while the seat is held';
    my $result = add_cart_line( $db, $run, $step,
        family_member_id => $kid->id, resource_id => $session->id, choice => $price->id . '/pay' );
    return ( $result, $run, $step );
}

subtest 'while the child holds its place, the session is refused' => sub {
    my ($result) = add();
    is $result->{errors}[0], sprintf( '%s already has a place in %s', $kid->child_name, $session->name ), 'refused';
};

subtest 'once it has ended, the child can buy the session again' => sub {
    $held->end( $db, 'refunded', 'dropped' );
    my ( $result, $run, $step ) = add();
    ok !$result->{errors}, 'the line is accepted' or diag explain $result->{errors};
    is_deeply $run->data->{cart_lines}, [ { family_member_id => $kid->id, resource_id => $session->id,
        offer_version_id => $price->id, payment_plan_id => 'pay' } ], 'and is in the cart';
};

done_testing;
