#!/usr/bin/env perl
# ABOUTME: is_student_enrolled must agree with the index that decides whether an insert collides.
# ABOUTME: A row it cannot see is a waitlist entry that can never be accepted.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers;
use Registry::DAO::Waitlist;
use Registry::DAO::Session;
use Registry::DAO::User;

my $t  = Test::Registry::DB->new;
my $dao = $t->db;

Test::Registry::Fixtures::create_tenant( $dao->db, {
    name => 'Waitlist Live Tenant', slug => 'test_waitlist_live',
} );
$dao->db->query( 'SELECT clone_schema(dest_schema => ?)', 'test_waitlist_live' );
$dao = Registry::DAO->new( url => $t->uri, schema => 'test_waitlist_live' );
my $db = $dao->db;

my $location = Registry::DAO::Location->create( $db, {
    name => 'Loc', address_info => {}, metadata => {},
} );
my $parent = Registry::DAO::User->create( $db, {
    email => 'p@waitlist-live.test', username => 'p_wl_live',
    password => 'password123', name => 'Parent', user_type => 'parent',
} );

my $seq = 0;
sub a_session {
    $seq++;
    return Registry::DAO::Session->create( $db, {
        name => "Live Check Week $seq",
        start_date => days_from_now(30), end_date => days_from_now(37),
        status => 'published', capacity => 10, metadata => {},
    } );
}

sub a_child ( $name ) {
    return Registry::DAO::Family->add_child( $db, $parent->id, {
        child_name => $name, birth_date => '2016-03-15', grade => '3',
        medical_info => {}, emergency_contact => { name => 'E', phone => '555-0123' },
    } );
}

# enrollments_session_student_type_live is UNIQUE (session_id, student_id,
# student_type) WHERE status IS DISTINCT FROM 'cancelled'. Anything that index
# covers will collide with accept_offer's insert, so the check has to see
# exactly that set -- no more, and no less.
sub seat_with_status ( $status ) {
    my $session = a_session();
    my $child   = a_child("Kid $seq");

    $db->insert( 'enrollments', {
        session_id       => $session->id,
        student_id       => $child->id,
        family_member_id => $child->id,
        parent_id        => $parent->id,
        student_type     => 'family_member',
        status           => $status,
    } );

    return ( $session, $child );
}

subtest 'a live row is seen whatever status it carries' => sub {
    for my $status ( 'active', 'pending', 'waitlisted' ) {
        my ( $session, $child ) = seat_with_status($status);
        ok Registry::DAO::Waitlist->is_student_enrolled( $db, $session->id, $child->id ),
            "a '$status' row occupies the slot";
    }
};

# status is nullable, and the index uses IS DISTINCT FROM precisely so a NULL
# row is still covered by it. A check using IN could never match one.
subtest 'a NULL-status row is seen too' => sub {
    my ( $session, $child ) = seat_with_status(undef);
    ok Registry::DAO::Waitlist->is_student_enrolled( $db, $session->id, $child->id ),
        'a NULL-status row occupies the slot';
};

# The other half of the index's rule, and the reason it is not simply "any row":
# a cancelled enrollment releases its seat so the child can re-join.
subtest 'a cancelled row does not block re-joining' => sub {
    my ( $session, $child ) = seat_with_status('cancelled');
    ok !Registry::DAO::Waitlist->is_student_enrolled( $db, $session->id, $child->id ),
        'a cancelled row leaves the slot free';
};

# The consequence the issue is filed for. Without the check seeing the
# waitlisted row, join_waitlist creates an entry whose accept_offer inserts over
# a live row and raises -- a free waitlist acceptance that dies.
subtest 'joining a waitlist over a live row is refused up front' => sub {
    my ( $session, $child ) = seat_with_status('waitlisted');

    throws_ok {
        Registry::DAO::Waitlist->join_waitlist(
            $db, $session->id, $location->id, $child->id, $parent->id );
    } qr/already enrolled/i, 'refused, rather than accepted and fatal later';
};

done_testing;
