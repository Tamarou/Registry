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
use Registry::DAO::Entitlement;
use Registry::DAO::FamilyMember;
use Registry::DAO::Offer;
use Test::Registry::Offers qw( offer_terms instalment_plan );
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

# A session is bought whole and a child attends it once: a place held now or
# later, active or past due, is never bought twice.
sub place ( $child, $session ) {
    return Registry::DAO::Entitlement->grant( $db, {
        holder_family_member_id => $child->id, payer_user_id => $parent->id,
        offer_version_id => $price{ $session->id }->id, payment_plan_id => 'pay',
        starts_at => '2026-01-01T00:00:00Z', resource_id => $session->id, units => 1,
    } );
}

subtest 'a child who already has a place in the session is refused' => sub {
    my $holder = child( $parent, 'Holder' );
    my $s      = scalar make_session( $db, days => [ map { days_from_now($_) } 30 .. 32 ] );
    $price{ $s->id } = session_offer( $db, $s );
    place( $holder, $s );

    my ( $run, $step ) = cart_run( $dao, $parent->id, $holder->id );
    my $result = add_cart_line( $db, $run, $step, family_member_id => $holder->id, resource_id => $s->id,
        choice => $price{ $s->id }->id . '/pay' );
    is $result->{errors}[0], sprintf( '%s already has a place in %s', $holder->child_name, $s->name ),
        'refused at add to cart, naming the child and the session';
    ok !$run->data->{cart_lines}, 'and nothing reaches the cart';
    is refusal( line( $holder, $s1 ) ), undef, 'another session is still open to the child';
};

subtest 'a past due place still counts' => sub {
    my $holder = child( $parent, 'Owing' );
    my $s      = scalar make_session( $db, days => [ map { days_from_now($_) } 30 .. 32 ] );
    $price{ $s->id } = session_offer( $db, $s );
    place( $holder, $s )->mark_past_due( $db, 'in_cart_past_due' );
    like refusal( line( $holder, $s ) ), qr/already has a place in/, 'refused';
};

subtest 'continue asks again when the place was taken after the line' => sub {
    my $late = child( $parent, 'Late' );
    my $s    = scalar make_session( $db, days => [ map { days_from_now($_) } 30 .. 32 ] );
    $price{ $s->id } = session_offer( $db, $s );
    my ( $run, $step ) = cart_run( $dao, $parent->id, $late->id );
    ok !add_cart_line( $db, $run, $step, family_member_id => $late->id, resource_id => $s->id,
        choice => $price{ $s->id }->id . '/pay' )->{errors}, 'a line is added';
    place( $late, $s );
    my $result = $run->process( $db, $step, { action => 'checkout', agree_to_terms => 1,
        terms_version_shown => Registry::Terms::VERSION } );
    like $result->{errors}[0], qr/^Late already has a place in/, 'continue refuses the line';
    ok !exists $run->data->{agreed_terms_version}, 'and records no agreement';
};

# A posted price is refused unless the cart would list it for that child now.
# Each is posted through the step; a refused one never reaches cart_lines.
sub posted ( $session, $version, $plan = 'pay' ) {
    my $buyer = child( $parent, 'Buyer' );
    my ( $run, $step ) = cart_run( $dao, $parent->id, $buyer->id );
    my $result = add_cart_line( $db, $run, $step, family_member_id => $buyer->id, resource_id => $session->id,
        choice => $version->id . "/$plan" );
    is scalar @{ $run->data->{cart_lines} // [] }, $result->{errors} ? 0 : 1,
        $result->{errors} ? 'nothing reaches the cart' : 'the line is in the cart';
    return $result->{errors}[0];
}

subtest 'an early bird price after its deadline is refused' => sub {
    my $s     = scalar make_session( $db, days => [ map { days_from_now($_) } 30 .. 32 ] );
    my $early = session_offer( $db, $s, conditions => [ { kind => 'before', at => '2026-01-01T00:00:00Z' } ] );
    is posted( $s, $early ), 'Choose one of the listed prices', 'refused';
};

subtest 'a superseded version is refused' => sub {
    my $s   = scalar make_session( $db, days => [ map { days_from_now($_) } 30 .. 32 ] );
    my $old = session_offer( $db, $s, price_cents => 20000 );
    my $new = Registry::DAO::Offer->find( $db, { id => $old->offer_id } )
        ->draft( $db, offer_terms( $s->id, price_cents => 25000 ) )->publish($db);
    is posted( $s, $old ), 'Choose one of the listed prices', 'the old price is refused';
    is posted( $s, $new ), undef, 'the current one is taken';
};

subtest "a plan id the version does not offer is refused" => sub {
    my $s = scalar make_session( $db, days => [ map { days_from_now($_) } 30 .. 32 ] );
    is posted( $s, session_offer( $db, $s ), 'parts' ), 'Choose one of the listed payment plans', 'refused';
};

subtest 'a posted instalment plan that no longer fits is refused' => sub {
    # Ten days out: a fourth weekly payment, three weeks away, is after the last day.
    my $s = scalar make_session( $db, days => [ map { days_from_now($_) } 10 .. 12 ] );
    my $v = session_offer( $db, $s,
        payment_plans => [ { id => 'pay', kind => 'one_time' }, instalment_plan( id => 'four', count => 4, cadence => 'weekly' ) ],
        policies => { refund => { kind => 'none' }, missed_payment => { kind => 'end' } } );
    is posted( $s, $v, 'four' ), 'Not offered: the last payment would fall after the session ends', 'refused';
};

done_testing;
