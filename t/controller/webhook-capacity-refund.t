# ABOUTME: The post-COMMIT capacity refund, driven end to end through the real webhook action.
# ABOUTME: Covers tenant schema routing, ordering after COMMIT, and that a failed refund still answers 2xx.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Mojo;
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Family;
use Registry::DAO::Payment;
use Registry::DAO::Enrollment;
use Registry::Service::Stripe;
use Digest::SHA qw(hmac_sha256_hex);
use Mojo::JSON qw(encode_json);
use Mojo::Pg;
use Mojo::Promise;

local $ENV{STRIPE_SECRET_KEY}     = 'sk_test_capacity_refund';
local $ENV{STRIPE_WEBHOOK_SECRET} = 'whsec_test_capacity_refund';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
my $uri     = $test_db->uri;

my $slug = 'cr_tenant_' . $$;

my $admin = Registry::DAO::User->create($db, {
    username => "cr_admin_$$", email => "cr_admin_$$\@test.example",
    name => 'CR Admin', user_type => 'admin' });
Registry::DAO::Tenant->provision($db, {
    name => "CR Tenant $$", slug => $slug, users => [$admin],
    stripe_connect_account_id => 'acct_cr_test',
    stripe_charges_enabled => 1, stripe_details_submitted => 1 });

my $tdao = Registry::DAO->new(url => $uri, schema => $slug);
my $tdb  = $tdao->db;

my $parent = Registry::DAO::User->create($tdb, {
    username => "cr_parent_$$", email => "cr_parent_$$\@test.example",
    name => 'CR Parent', user_type => 'parent' });

my $seq = 0;
sub a_child () {
    $seq++;
    Registry::DAO::Family->add_child($tdb, $parent->id, {
        child_name => "CR Kid $seq", birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' } });
}

my $loc = Registry::DAO::Location->create($tdb, {
    name => "CR Studio $$", slug => "cr_studio_$$", address_info => {}, metadata => {} });
my $prog = Registry::DAO::Project->create($tdb, {
    name => "CR Camp $$", status => 'published',
    program_type_slug => 'summer-camp', metadata => {} });
my $teacher = Registry::DAO::User->create($tdb, {
    username => "cr_teacher_$$", email => "cr_teacher_$$\@test.example",
    name => 'CR Teacher', user_type => 'staff' });

sub a_full_session () {
    $seq++;
    my $s = Registry::DAO::Session->create($tdb, {
        name => "CR Week $seq", start_date => '2026-07-01', end_date => '2026-07-31',
        status => 'published', capacity => 1, metadata => {} });
    my $e = Registry::DAO::Event->create($tdb, {
        time => sprintf('2026-07-01 %02d:%02d:00', $seq % 24, $seq % 60),
        duration => 60, location_id => $loc->id, project_id => $prog->id,
        teacher_id => $teacher->id, capacity => 1, metadata => {} });
    $s->add_events($tdb, $e->id);
    # Somebody else already holds the only seat.
    Registry::DAO::Enrollment->create($tdb, {
        session_id => $s->id, family_member_id => a_child()->id,
        parent_id => $parent->id, status => 'active' });
    return $s;
}

# A captured tenant payment for a seat that is gone.
sub a_doomed_payment () {
    my $session = a_full_session();
    my $child   = a_child();
    my $p = Registry::DAO::Payment->create($tdb, {
        user_id => $parent->id, amount_cents => 15000, status => 'pending',
        metadata => {
            enrollment_items => [ { session_id => $session->id, child_id => $child->id } ],
            tenant_slug      => $slug } });
    $tdb->insert('payment_items', {
        payment_id => $p->id, description => 'seat', amount_cents => 15000,
        metadata => { -json => { child_id => $child->id, session_id => $session->id } } });
    return Registry::DAO::Payment->find($tdb, { id => $p->id });
}

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

my $evt = 0;
sub post_settlement ($payment) {
    $evt++;
    my $event = {
        id   => "evt_cr_${$}_$evt",
        type => 'payment_intent.succeeded',
        data => { object => {
            id       => 'pi_cr_' . $payment->id,
            amount   => 15000,
            metadata => { payment_id => $payment->id, tenant_slug => $slug },
        } },
    };
    my $payload   = encode_json($event);
    my $timestamp = time();
    my $sig       = hmac_sha256_hex("$timestamp.$payload", $ENV{STRIPE_WEBHOOK_SECRET});
    return $t->tx( $t->ua->post('/webhooks/stripe' => {
        'stripe-signature' => "t=$timestamp,v1=$sig",
        'Content-Type'     => 'application/json',
    } => $payload) );
}

sub tenant_payment ($payment) {
    Registry::DAO::Payment->find($tdb, { id => $payment->id });
}

subtest 'the refund lands in the tenant schema, not registry' => sub {
    my $payment = a_doomed_payment();
    my @refunds;

    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async = sub ($s, $p) {
            push @refunds, $p;
            Mojo::Promise->resolve({ id => 're_cr', status => 'succeeded' });
        };
        post_settlement($payment)->status_is(200);
    }

    is scalar @refunds, 1, 'the capacity refund was issued';
    is $refunds[0]{amount}, 15000, "for the demoted child's share";

    # By qualified name on both sides. An assertion that read whatever
    # unqualified `payments` resolves to would pass even if the write had
    # landed in the wrong schema, which is the failure this guards.
    my $in_tenant = $db->query(
        sprintf(q{SELECT status FROM %s.payments WHERE id = ?}, $db->dbh->quote_identifier($slug)),
        $payment->id)->hash;
    is $in_tenant->{status}, 'refunded', 'the tenant row records the refund';

    my $in_registry = $db->query(
        'SELECT COUNT(*) FROM registry.payments WHERE id = ?', $payment->id)->array->[0];
    is $in_registry, 0, 'and registry.payments gained nothing';
};

# One increment cannot tell the two apart: the balance and the increment are
# the same number, so a caller sending refund_owed_cents passes just as well as
# one sending $inc->{cents}. Two increments separate them, and sending the
# balance is precisely the double refund this whole design exists to stop.
subtest 'two increments are refunded separately, never as one accumulated total' => sub {
    my $payment = a_doomed_payment();

    # A second, earlier debt whose refund never settled -- the shape a lost
    # response leaves behind.
    #
    # The intent id has to be seeded with it. Recording a debt moves the row to
    # refund_pending, which makes the delivery below skip mark_completed --
    # correct, that is the settled-write guard doing its job -- so the row would
    # never acquire an intent id and refund_async would die on that instead,
    # invisibly, because the always-2xx catch swallows it. In production the
    # first delivery completes the payment before any debt exists.
    $tdb->update('payments', { stripe_payment_intent_id => 'pi_multi_' . $payment->id },
        { id => $payment->id });
    tenant_payment($payment)->record_capacity_obligation( $tdb, 4000, ['earlier-kid'] );

    my @refunds;
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async = sub ($s, $p) {
            push @refunds, $p;
            Mojo::Promise->resolve({ id => 're_multi_' . scalar(@refunds), status => 'succeeded' });
        };
        post_settlement($payment)->status_is(200);
    }

    is scalar @refunds, 2, 'one Stripe call per unsettled increment';
    # 4000 + 11000, not 4000 + 15000: the cart is 15000, so the second
    # increment is clamped to the headroom left. The increments always sum to
    # the balance, which is the property that keeps Stripe from being sent more
    # than the payment.
    is_deeply [ sort { $a <=> $b } map { $_->{amount} } @refunds ], [ 4000, 11000 ],
        'each for its own amount -- not the 15000 balance twice, nor once';

    my $total = 0; $total += $_->{amount} for @refunds;
    is $total, 15000, 'the total reaching Stripe equals the debt, never more';

    my %keys = map { $_->{_idempotency_key} // '' => 1 } @refunds;
    is scalar( keys %keys ), 2,
        'under distinct keys, so Stripe cannot fold one into the other';

    is tenant_payment($payment)->refund_owed_cents, 0, 'and nothing is left owed';
};

subtest 'the refund happens after the COMMIT, not inside it' => sub {
    my $payment = a_doomed_payment();
    my $visible_to_another_connection;

    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async = sub ($s, $p) {
            # A second backend can only see the demotion if the settlement
            # transaction has already committed.
            my $other = Mojo::Pg->new($uri)->db;
            $visible_to_another_connection = $other->query(
                sprintf(q{SELECT status FROM %s.payments WHERE id = ?},
                    $other->dbh->quote_identifier($slug)),
                $payment->id)->hash->{status};
            Mojo::Promise->resolve({ id => 're_cr_order', status => 'succeeded' });
        };
        post_settlement($payment)->status_is(200);
    }

    is $visible_to_another_connection, 'refund_pending',
        'the settlement was committed before the refund was issued';
};

subtest 'a rejected refund still answers Stripe with 2xx' => sub {
    # A 500 here would make Stripe retry a delivery whose claim is committed;
    # the retry hits the dedup, is acknowledged as a duplicate, and the refund
    # is never retried -- while repeated 500s on successful deliveries are how
    # an endpoint gets disabled.
    my $payment = a_doomed_payment();
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async =
            sub { Mojo::Promise->reject('card network unavailable') };
        post_settlement($payment)->status_is(200);
    }
    is tenant_payment($payment)->status, 'refund_pending',
        'and leaves the row for the runbook';
};

subtest 'a refund that throws synchronously still answers 2xx' => sub {
    # refund_async dies before returning a promise in several real ways: the
    # status guard, a missing intent id, stripe_client refusing a live key. A
    # ->catch on the returned promise never sees a synchronous throw, so the
    # exception escapes the action entirely.
    my $payment = a_doomed_payment();
    {
        no warnings 'redefine';
        local *Registry::DAO::Payment::refund_async =
            sub { die "stripe_client initialization failed\n" };
        post_settlement($payment)->status_is(200);
    }
    is tenant_payment($payment)->status, 'refund_pending',
        'the debt survives the throw';
};

subtest 'a settlement that fits refunds nothing' => sub {
    $seq++;
    my $roomy = Registry::DAO::Session->create($tdb, {
        name => "CR Roomy $seq", start_date => '2026-07-01', end_date => '2026-07-31',
        status => 'published', capacity => 10, metadata => {} });
    my $e = Registry::DAO::Event->create($tdb, {
        time => sprintf('2026-08-01 %02d:%02d:00', $seq % 24, $seq % 60),
        duration => 60, location_id => $loc->id, project_id => $prog->id,
        teacher_id => $teacher->id, capacity => 10, metadata => {} });
    $roomy->add_events($tdb, $e->id);

    my $child = a_child();
    my $p = Registry::DAO::Payment->create($tdb, {
        user_id => $parent->id, amount_cents => 15000, status => 'pending',
        metadata => {
            enrollment_items => [ { session_id => $roomy->id, child_id => $child->id } ],
            tenant_slug      => $slug } });
    my $payment = Registry::DAO::Payment->find($tdb, { id => $p->id });

    my @refunds;
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async =
            sub ($s, $pp) { push @refunds, $pp; Mojo::Promise->resolve({ id => 're_no' }) };
        post_settlement($payment)->status_is(200);
    }

    is scalar @refunds, 0, 'no refund is issued for a seat that was there';
    is tenant_payment($payment)->status, 'completed', 'and the payment is completed';
};

done_testing;
