#!/usr/bin/env perl
# ABOUTME: Line-item descriptions on a payment name the child they are charging for.
# ABOUTME: The name has to survive whichever shape the cart's children snapshot arrives in.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers;
use Registry::DAO::Family;
use Registry::DAO::Payment;
use Registry::DAO::PricingPlan;
use Registry::DAO::Session;
use Registry::DAO::User;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

Test::Registry::Fixtures::create_tenant( $dao->db, {
    name => 'Line Item Tenant', slug => 'test_line_item',
} );
$dao->db->query( 'SELECT clone_schema(?)', 'test_line_item' );
$dao = Registry::DAO->new( url => $test_db->uri, schema => 'test_line_item' );
my $db = $dao->db;

my $session = Registry::DAO::Session->create( $db, {
    name       => 'Pottery Week',
    start_date => days_from_now(30),
    end_date   => days_from_now(37),
    status     => 'published',
    metadata   => {},
} );
Registry::DAO::PricingPlan->create( $db, {
    session_id => $session->id, plan_name => 'Standard',
    plan_type  => 'standard',  amount_cents => 15000,
} );

my $parent = Registry::DAO::User->create( $db, {
    email => 'p@line-item.test', username => 'p_line_item',
    password => 'password123', name => 'Parent', user_type => 'parent',
} );
my $child = Registry::DAO::Family->add_child( $db, $parent->id, {
    child_name => 'Ada Lovelace', birth_date => '2016-03-15', grade => '3',
    medical_info => {}, emergency_contact => { name => 'E', phone => '555-0123' },
} );

sub describe ( $child_data ) {
    my @warnings;
    my $info = do {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        Registry::DAO::Payment->calculate_enrollment_total( $db, {
            children           => [$child_data],
            session_selections => { $child_data->{id} => $session->id },
        } );
    };
    return ( $info->{items}[0]{description}, join( '', @warnings ) );
}

# family_members carries a single child_name column. This is the shape a child
# read straight off the family tables has.
subtest 'a child carrying child_name is named on the line item' => sub {
    my ( $description, $warnings ) =
      describe( { id => $child->id, child_name => 'Ada Lovelace' } );

    is $description, 'Ada Lovelace - Pottery Week', 'the child and the session';
    is $warnings, '', 'and no uninitialized-value warnings';
};

# MultiChildSessionSelection snapshots the cart with first_name set to the whole
# child_name and last_name set to the empty string. Interpolating both put two
# spaces before the dash.
subtest 'the run-data snapshot shape is named without a doubled space' => sub {
    my ( $description, $warnings ) =
      describe( { id => $child->id, first_name => 'Ada Lovelace', last_name => '' } );

    is $description, 'Ada Lovelace - Pottery Week', 'one space before the dash';
    is $warnings, '', 'and no uninitialized-value warnings';
};

# A cart that names no child at all must not interpolate undef into a receipt.
subtest 'a child with no name at all still yields a usable description' => sub {
    my ( $description, $warnings ) = describe( { id => $child->id } );

    is $warnings, '', 'no uninitialized-value warnings';
    unlike $description, qr/^\s|\s{2}/, 'no leading or doubled space';
    like $description, qr/Pottery Week/, 'the session is still named';
};

done_testing;
