# ABOUTME: Test helper making a session, one finite resource whose days are its events, and offers selling it.
# ABOUTME: Makes the project, location and teacher it needs; tests override only what they are about.
use 5.42.0;
use warnings;

package Test::Registry::Sessions;

use Exporter 'import';
our @EXPORT_OK = qw( make_session session_offer cart_run add_cart_line cart_at_hold held_cart );

use Test::Registry::Fixtures;
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO::Resource;
use Registry::DAO::Offer;
use Registry::Terms;

my $made = 0;

# make_session($db, %overrides): a session of three days from 2027-06-07,
# 09:00 for 420 minutes, twelve seats, no waitlist. time_zone names the zone
# of the location made for it (default America/New_York).
sub make_session ( $db, %o ) {
    my $n  = ++$made;
    my $tz = delete $o{time_zone} // 'America/New_York';
    $o{project_id} //= Test::Registry::Fixtures::create_project( $db,
        { name => "Session program $n", slug => "session-program-$n" } )->id;
    $o{location_id} //= Test::Registry::Fixtures::create_location( $db,
        { name => "Session room $n", slug => "session-room-$n", time_zone => $tz } )->id;
    $o{teacher_id} //= Test::Registry::Fixtures::create_user( $db, { username => "session-teacher-$n" } )->id;
    return Registry::DAO::Resource->create_session( $db, {
        name     => "Session $n",
        capacity => 12,
        waitlist => { kind => 'none' },
        days     => [qw( 2027-06-07 2027-06-08 2027-06-09 )],
        start    => '09:00',
        minutes  => 420,
        %o,
    } );
}

# session_offer($db, $session, %terms): a published version of a new offer
# selling $session, its terms offer_terms' overridden by %terms.
sub session_offer ( $db, $session, %terms ) {
    my $n = ++$made;
    return Registry::DAO::Offer->create( $db, { name => "Session offer $n" } )
        ->draft( $db, offer_terms( $session->id, %terms ) )->publish($db);
}

# cart_run($dao, $payer_id, @child_ids): a session-checkout run whose signed-in
# payer is $payer_id with @child_ids chosen, and its cart step. Imports the
# workflow into $dao's schema.
sub cart_run ( $dao, $payer_id, @child_ids ) {
    $dao->import_workflows( ['workflows/session-checkout.yml'] );
    my $db       = $dao->db;
    my $workflow = $dao->find( Workflow => { slug => 'session-checkout' } );
    my $run      = $workflow->new_run($db);
    $run->update_data( $db, { user_id => $payer_id, selected_child_ids => \@child_ids } );
    return ( $run, $workflow->get_step( $db, { slug => 'cart' } ) );
}

# add_cart_line($db, $run, $step, %line): posts a line to the cart as its page
# does (family_member_id, resource_id, choice); returns the step's result.
sub add_cart_line ( $db, $run, $step, %line ) {
    return $run->process( $db, $step, { action => 'add_line', %line } );
}

# cart_at_hold($dao, $payer_id, @lines): a session-checkout run whose cart has
# @lines, each [ $child_id, $session_id, $version_id, $plan_id ], checked out
# with the /terms agreed, and its hold step. Dies if the cart refuses a line.
sub cart_at_hold ( $dao, $payer_id, @lines ) {
    my %children = map { $_->[0] => 1 } @lines;
    my ( $run, $cart ) = cart_run( $dao, $payer_id, sort keys %children );
    my $db = $dao->db;
    for my $line (@lines) {
        my ( $child, $session, $version, $plan ) = @$line;
        my $added = add_cart_line( $db, $run, $cart, family_member_id => $child, resource_id => $session,
            choice => "$version/$plan" );
        die "line refused: $added->{errors}[0]\n" if $added->{errors};
    }
    my $out = $run->process( $db, $cart, { action => 'checkout', agree_to_terms => 1,
        terms_version_shown => Registry::Terms::VERSION } );
    die "checkout refused: $out->{errors}[0]\n" if $out->{errors};
    return ( $run, $dao->find( Workflow => { slug => 'session-checkout' } )->get_step( $db, { slug => 'hold' } ) );
}

# held_cart($dao, $payer_id, @lines): a run as cart_at_hold makes it, sold by
# $dao's schema's tenant, with every line's seat held and the cart's charge
# owed, and its payment step. Dies if the hold refuses.
sub held_cart ( $dao, $payer_id, @lines ) {
    my ( $run, $hold ) = cart_at_hold( $dao, $payer_id, @lines );
    my $db = $dao->db;
    $run->update_data( $db, { __tenant_slug => $dao->schema } );
    my $out = $run->process( $db, $hold, {} );
    die "hold refused: $out->{errors}[0]\n" if $out->{errors};
    return ( $run, $dao->find( Workflow => { slug => 'session-checkout' } )->get_step( $db, { slug => 'payment' } ) );
}

1;
