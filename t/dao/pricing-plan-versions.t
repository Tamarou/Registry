# ABOUTME: Tests PriceOps pillars 1 and 2 -- immutable plan versions, and a recoverable pricing basis.
# ABOUTME: Also pillar 4: requirements come from what a plan declares, not from its type name.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Family;
use Registry::DAO::PricingPlan;
use Registry::DAO::Payment;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $loc = $dao->create(Location => {
    name => 'Version Studio', slug => 'version-studio', address_info => {}, metadata => {},
});
my $prog = $dao->create(Project => {
    status => 'published', name => 'Version Camp', program_type_slug => 'summer-camp', metadata => {},
});
my $teacher = $dao->create(User => {
    username => 'ver_teacher', name => 'T', user_type => 'staff', email => 'vt@test.local',
});
my $parent = $dao->create(User => {
    username => 'ver_parent', name => 'Version Parent', user_type => 'parent', email => 'vp@test.local',
});
my ($kid, $sibling) = map {
    Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => $_, birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
    })
} 'Version Kid', 'Version Sibling';

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

sub quote_for ( $session, @children ) {
    return Registry::DAO::Payment->calculate_enrollment_total($db, {
        children           => [@children],
        session_selections => { map { $_->{id} => $session->id } @children },
    });
}

sub child_row ($child, $name) {
    return { id => $child->id, first_name => $name, last_name => '', grade => '3' };
}

# ---------------------------------------------------------------------------
# Pillar 1: append-only, versioned, immutable
# ---------------------------------------------------------------------------

subtest 'a new plan is the first version of its own family' => sub {
    my $session = make_session('Family Identity');
    my $plan = Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id, plan_name => 'Standard',
        plan_type => 'standard', amount_cents => 30000,
    });

    is $plan->version, 1, 'it is version 1';
    is $plan->plan_family_id, $plan->id, 'and its own family';
    is $plan->superseded_at, undef, 'current, not retired';
};

subtest 'a plan version cannot be edited in place' => sub {
    my $session = make_session('Immutable Terms');
    my $plan = Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id, plan_name => 'Standard',
        plan_type => 'standard', amount_cents => 30000,
    });

    my $ok = eval { $plan->update($db, { amount_cents => 10000 }); 1 };
    ok !$ok, 'changing the price in place is refused';
    like $@, qr/immutable/, 'and says why';
    like $@, qr/revise/, 'and what to use instead';

    my $reread = Registry::DAO::PricingPlan->find($db, { id => $plan->id });
    is $reread->amount_cents, 30000, 'the price is unchanged';
};

subtest 'a plan cannot be edited by raw SQL either' => sub {
    # The DAO croak above is only a better error message. This is the enforcement:
    # a BEFORE UPDATE trigger, because psql is the platform owner's only pricing
    # tooling today (#426) and RevenueShare reads the rate off the row on every
    # charge -- so a hand-edit would silently re-price without passing through any
    # Perl at all.
    my $session = make_session('Immutable In The Database');
    my $plan = Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id, plan_name => 'Standard',
        plan_type => 'standard', amount_cents => 30000,
    });

    my $ok = eval {
        $db->query('UPDATE pricing_plans SET amount_cents = 1 WHERE id = ?', $plan->id);
        1;
    };
    ok !$ok, 'the database refuses the update';
    like $@, qr/immutable/, 'and says so';

    is Registry::DAO::PricingPlan->find($db, { id => $plan->id })->amount_cents,
        30000, 'the price is unchanged';

    # A column added to this table later is protected automatically, because the
    # trigger subtracts what is allowed rather than listing what is guarded.
    my $meta_ok = eval {
        $db->query(q{UPDATE pricing_plans SET metadata = '{"x":1}'::jsonb WHERE id = ?},
            $plan->id);
        1;
    };
    ok !$meta_ok, 'and refuses a change to any other column too';

    # Retiring is not changing the terms, so it is permitted -- this is the
    # exemption revise relies on.
    my $retire_ok = eval {
        $db->query('UPDATE pricing_plans SET superseded_at = now() WHERE id = ?', $plan->id);
        1;
    };
    ok $retire_ok, 'but retiring a version is allowed' or diag "refused: $@";
};

subtest 'revising appends a version and retires the old one' => sub {
    my $session = make_session('Revised');
    my $v1 = Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id, plan_name => 'Standard',
        plan_type => 'standard', amount_cents => 30000,
    });

    my $v2 = $v1->revise($db, { amount_cents => 35000 });

    is $v2->version, 2, 'the new version is 2';
    is $v2->plan_family_id, $v1->plan_family_id, 'in the same family';
    is $v2->amount_cents, 35000, 'carrying the new price';
    is $v2->plan_name, 'Standard', 'and the terms not changed';
    isnt $v2->id, $v1->id, 'as a different row';

    my $old = Registry::DAO::PricingPlan->find($db, { id => $v1->id });
    ok defined $old->superseded_at, 'the old version is retired';
    is $old->amount_cents, 30000,
        'and still says what it charged -- which is the point of keeping it';

    my $current = Registry::DAO::PricingPlan->current_for_family($db, $v1->plan_family_id);
    is $current->id, $v2->id, 'the current version is the new one';

    is scalar @{ $v2->versions($db) }, 2, 'both versions are retrievable';
};

subtest 'only the current version is on offer' => sub {
    my $session = make_session('Retired Not Sold');
    my $v1 = Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id, plan_name => 'Standard',
        plan_type => 'standard', amount_cents => 30000,
    });
    $v1->revise($db, { amount_cents => 35000 });

    my $offered = Registry::DAO::PricingPlan->get_pricing_plans($db, $session->id);
    is scalar @$offered, 1, 'one plan on offer, not two';
    is $offered->[0]->version, 2, 'the current version';

    # The load-bearing consequence: a retired cheaper version must not keep
    # winning the best-price comparison, or retiring a price would not stop
    # anybody being charged it.
    is quote_for( $session, child_row($kid, 'Version Kid') )->{total}, 35000,
        'the cart charges the current price, not the retired cheaper one';
};

subtest 'a superseded version cannot itself be revised' => sub {
    my $session = make_session('No Branching');
    my $v1 = Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id, plan_name => 'Standard',
        plan_type => 'standard', amount_cents => 30000,
    });
    $v1->revise($db, { amount_cents => 35000 });

    my $ok = eval { $v1->revise($db, { amount_cents => 1 }); 1 };
    my $err = $@;
    ok !$ok, 'revising a retired version is refused';
    like $err, qr/superseded/, 'naming the reason';

    # And the retirement it attempted is undone, so the current version is still
    # current -- a failed revise must not leave the family with no live version.
    my $current = Registry::DAO::PricingPlan->current_for_family($db, $v1->plan_family_id);
    ok $current, 'the family still has a current version';
    is $current->version, 2, 'and it is still version 2';
};

# ---------------------------------------------------------------------------
# Pillar 2: the charge records its pricing basis
# ---------------------------------------------------------------------------

subtest 'a line item records the plan version that priced it' => sub {
    my $session = make_session('Attributed');
    my $plan = Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id, plan_name => 'Standard',
        plan_type => 'standard', amount_cents => 30000,
    });

    my $quote = quote_for( $session, child_row($kid, 'Version Kid') );
    is $quote->{total}, 30000, 'priced';
    is $quote->{items}[0]{pricing_plan_id}, $plan->id,
        'the quote names the plan version it used';

    # And it survives being written: a basis computed and dropped at the insert
    # is no basis at all.
    my $payment = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => $quote->{total}, metadata => {},
    });
    $payment->add_line_item($db, $quote->{items}[0]);

    my $row = $db->select('payment_items', '*', { payment_id => $payment->id })->hash;
    is $row->{pricing_plan_id}, $plan->id,
        'and the stored line item carries it';
};

subtest 'the recorded version is the one that was current at the time' => sub {
    my $session = make_session('Basis Survives');
    my $v1 = Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id, plan_name => 'Standard',
        plan_type => 'standard', amount_cents => 30000,
    });

    my $quote = quote_for( $session, child_row($kid, 'Version Kid') );
    my $charged_under = $quote->{items}[0]{pricing_plan_id};
    is $charged_under, $v1->id, 'charged under v1';

    # The price changes afterwards. The old charge must still resolve to what it
    # actually cost -- this is what in-place editing destroyed.
    $v1->revise($db, { amount_cents => 35000 });

    my $basis = Registry::DAO::PricingPlan->find($db, { id => $charged_under });
    is $basis->amount_cents, 30000,
        'and the basis still reads 30000 after the plan was revised upward';
};

# ---------------------------------------------------------------------------
# Pillar 4: declared requirements, not plan-type names
# ---------------------------------------------------------------------------

subtest 'a declared cutoff is honoured whatever the plan is called' => sub {
    my $session = make_session('Declared Cutoff');

    # plan_type 'subscription' is one of the four the creation screen offers and
    # none of which the engine used to recognise -- so this plan's cutoff was
    # stored, shown, and silently ignored.
    Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id, plan_name => 'Closed Promo',
        plan_type => 'subscription', amount_cents => 10000,
        requirements => { early_bird_cutoff_date => '2020-01-01' },
    });
    Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id, plan_name => 'Standard',
        plan_type => 'standard', amount_cents => 30000,
    });

    is quote_for( $session, child_row($kid, 'Version Kid') )->{total}, 30000,
        'the expired promo is not charged even though its type is not early_bird';
};

subtest 'a declared minimum is honoured whatever the plan is called' => sub {
    my $session = make_session('Declared Minimum');

    Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id, plan_name => 'Standard',
        plan_type => 'standard', amount_cents => 30000,
    });
    Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id, plan_name => 'Two Or More',
        plan_type => 'one_time', amount_cents => 30000,
        requirements => { min_children => 2, percentage_discount => 20 },
    });

    is quote_for( $session, child_row($kid, 'Version Kid') )->{total}, 30000,
        'one child does not qualify';
    is quote_for( $session,
        child_row($kid, 'Version Kid'), child_row($sibling, 'Version Sibling') )->{total},
        48000, 'two children get the declared discount, on a one_time plan';
};

done_testing;
