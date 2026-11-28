#!/usr/bin/env perl
# ABOUTME: Tests the Stripe Connect readiness gate in the session cart's payment step.
# ABOUTME: A cart is not charged while the selling tenant's connected account is not ready.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::PricingProbe qw( state_platform_terms );
use Test::Registry::Helpers qw( days_from_now );
use Test::Registry::Sessions qw( make_session session_offer held_cart );
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::FamilyMember;
use Test::Registry::Async qw( settle );
use Registry::Service::Stripe;
use Mojo::Promise;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# Provision a fresh tenant so we have a real tenant schema with proper isolation.
# Tenant->provision creates the tenant row in registry.tenants AND clones the schema.
my $slug = 'gate_test_' . $$;
my $admin = Registry::DAO::User->create($db, {
    username  => "gate_admin_$$",
    email     => "gate_admin_$$\@test.example",
    name      => 'Gate Admin',
    user_type => 'admin',
});

my $tenant = Registry::DAO::Tenant->provision($db, {
    name  => "Gate Test $$",
    slug  => $slug,
    users => [ $admin ],
});
ok $tenant, 'tenant provisioned';
state_platform_terms( $db, $slug, { rate => 0 } );

my $tenant_dao = Registry::DAO->new(url => $test_db->uri, schema => $slug);
my $tenant_db  = $tenant_dao->db;

my $parent = Registry::DAO::User->create($tenant_db, {
    email     => "gate_parent_$$\@example.com",
    username  => "gate_parent_$$",
    name      => 'Gate Parent',
    user_type => 'parent',
});
my $child = Registry::DAO::FamilyMember->create($tenant_db, {
    family_id => $parent->id, child_name => 'Gate Child', birth_date => '2016-03-15' });

# A cart of the child in a $150 session, held and owing, and its payment step.
sub held () {
    my $session = make_session( $tenant_db, days => [ map { days_from_now($_) } 30 .. 32 ] );
    my $version = session_offer( $tenant_db, $session, price_cents => 15000 );
    return held_cart( $tenant_dao, $parent->id, [ $child->id, $session->id, $version->id, 'pay' ] );
}

sub payments () { $tenant_db->select('payments', ['id'], { user_id => $parent->id })->hashes->size }

# ---- case (a): tenant NOT Stripe-ready - gate blocks ------------------------
subtest 'paid + tenant not ready: gate returns error, no payment row' => sub {
    ok !$tenant->stripe_connect_ready, 'tenant not yet Stripe Connect ready';

    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';

    my ( $run, $step ) = held();
    my @warnings;
    my $result = do {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        settle($run->process($tenant_db, $step, {}));
    };
    like "@warnings", qr/payment refused: tenant '\Q${\ $tenant->slug }\E' is not Stripe Connect ready/,
        'the refusal is logged';

    is_deeply $result->{errors}, ['This payment cannot be taken right now. Nothing has been charged.'],
        'gate returned the unavailable message';
    is $run->next_step($tenant_db)->slug, 'payment', 'stays on payment step (not advanced)';
    is payments(), 0, 'no payment row created when gate fires';
};

# ---- case (b): tenant IS Stripe-ready - proceeds ----------------------------
subtest 'paid + tenant ready: gate passes, payment row created' => sub {
    $db->query(
        'UPDATE registry.tenants SET stripe_connect_account_id = $1, stripe_charges_enabled = TRUE, stripe_details_submitted = TRUE WHERE slug = $2',
        'acct_gate_test', $slug,
    );

    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';

    my $intent_called = 0;
    no warnings 'redefine';
    # The step drives Stripe through the async seam; a blocking call in the
    # web path can never settle inside the daemon's running event loop.
    local *Registry::Service::Stripe::create_payment_intent_async = sub {
        $intent_called++;
        return Mojo::Promise->resolve({ id => 'pi_gate_test', client_secret => 'cs_gate_test' });
    };

    my ( $run, $step ) = held();
    my $result = settle($run->process($tenant_db, $step, {}));

    ok !$result->{errors}, 'no gate error when tenant is ready' or diag explain $result->{errors};
    ok $intent_called, 'Stripe payment intent was called';
    is payments(), 1, 'payment row created in tenant schema';
};

$test_db->cleanup_test_database;
done_testing;
