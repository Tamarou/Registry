# ABOUTME: Tests that a cart is priced by the cheapest plan whose requirements it meets.
# ABOUTME: MVP §3 -- early bird and sibling discounts -- which no suite owned before #395.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Family;
use Registry::DAO::Payment;
use Registry::DAO::PricingPlan;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $loc = $dao->create(Location => {
    name => 'Pricing Studio', slug => 'pricing-studio', address_info => {}, metadata => {},
});
my $prog = $dao->create(Project => {
    status => 'published', name => 'Pricing Camp', program_type_slug => 'summer-camp', metadata => {},
});
my $teacher = $dao->create(User => {
    username => 'pricing_teacher', name => 'T', user_type => 'staff', email => 'pt@test.local',
});
my $parent = $dao->create(User => {
    username => 'pricing_parent', name => 'Pricing Parent', user_type => 'parent',
    email => 'pp@test.local',
});

my ($kid, $sibling) = map {
    Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => $_, birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
    })
} 'First Kid', 'Second Kid';

my $hour = 9;
sub make_session ($name) {
    my $session = $dao->create(Session => {
        name => $name, start_date => '2026-01-01', end_date => '2026-12-31',
        status => 'published', capacity => 20, metadata => {},
    });
    my $event = $dao->create(Event => {
        time => sprintf('2026-06-15 %02d:00:00', $hour++), duration => 60,
        location_id => $loc->id, project_id => $prog->id, teacher_id => $teacher->id,
        capacity => 20, metadata => {},
    });
    $session->add_events($db, $event->id);
    return $session;
}

# The child snapshot shape MultiChildSessionSelection writes.
sub child_row ($child, $name) {
    return { id => $child->id, first_name => $name, last_name => '', grade => '3' };
}

sub total_for ( $session, @children ) {
    my $info = Registry::DAO::Payment->calculate_enrollment_total($db, {
        children           => [@children],
        session_selections => { map { $_->{id} => $session->id } @children },
    });
    return $info;
}

subtest 'an early bird price still open is what the cart charges' => sub {
    my $session = make_session('Early Bird Open');

    # Standard written FIRST, so a cart that simply takes the first row it is
    # handed would charge the higher price here.
    Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id, plan_name => 'Standard',
        plan_type => 'standard', amount_cents => 30000,
    });
    Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id, plan_name => 'Early Bird',
        plan_type => 'early_bird', amount_cents => 20000,
        requirements => { early_bird_cutoff_date => '2030-01-01' },
    });

    my $info = total_for( $session, child_row($kid, 'First Kid') );
    is $info->{total}, 20000, 'the open early bird price is charged, not the standard one';
    is scalar @{ $info->{items} }, 1, 'and the child has a line item';
};

subtest 'an early bird price that has closed falls back to standard' => sub {
    my $session = make_session('Early Bird Closed');

    # Early bird written FIRST and expired. Taking the first plan returns undef
    # from calculate_price -- the requirements are not met -- and the child was
    # then skipped entirely: no line item, nothing added to the total, and still
    # present in enrollment_items. A cart that enrolled a child for nothing.
    Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id, plan_name => 'Early Bird',
        plan_type => 'early_bird', amount_cents => 20000,
        requirements => { early_bird_cutoff_date => '2020-01-01' },
    });
    Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id, plan_name => 'Standard',
        plan_type => 'standard', amount_cents => 30000,
    });

    my $info = total_for( $session, child_row($kid, 'First Kid') );
    is $info->{total}, 30000, 'the standard price is charged';
    is scalar @{ $info->{items} }, 1, 'and the child is priced rather than skipped';
};

subtest 'a family plan applies once there are enough children' => sub {
    my $session = make_session('Family Discount');

    Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id, plan_name => 'Standard',
        plan_type => 'standard', amount_cents => 30000,
    });
    # 20% off each child, from the second child onwards. child_count was
    # hardcoded to 1 in the cart, so min_children could never be satisfied and
    # the sibling discount -- an MVP pricing feature -- was unreachable.
    Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id, plan_name => 'Family Rate',
        plan_type => 'family', amount_cents => 30000,
        requirements => { min_children => 2, percentage_discount => 20 },
    });

    my $one = total_for( $session, child_row($kid, 'First Kid') );
    is $one->{total}, 30000, 'one child pays the standard price';

    my $two = total_for( $session,
        child_row($kid, 'First Kid'), child_row($sibling, 'Second Kid') );
    is $two->{total}, 48000, 'two children pay the family rate each ($240 x 2)';
    is scalar @{ $two->{items} }, 2, 'with a line item per child';
    is $two->{items}[0]{amount_cents}, 24000, 'each line is the discounted amount';
};

subtest 'a session with no applicable plan prices nothing rather than guessing' => sub {
    my $session = make_session('Nothing Applies');

    # The only plan needs three children and the cart has one. There is no price
    # to charge, so there is no line -- the condition finalize_enrollment already
    # flags for a human rather than one this should invent a number for.
    Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id, plan_name => 'Big Family Only',
        plan_type => 'family', amount_cents => 30000,
        requirements => { min_children => 3, percentage_discount => 50 },
    });

    my $info = total_for( $session, child_row($kid, 'First Kid') );
    is $info->{total}, 0, 'nothing is charged';
    is scalar @{ $info->{items} }, 0, 'and no line is invented';
};

done_testing;
