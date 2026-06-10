# ABOUTME: Tests that create_payment_intent sends Stripe params flattened in
# ABOUTME: bracket notation (form encoding cannot serialize nested hashrefs).
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Payment;
use Registry::Service::Stripe;

my $t   = Test::Registry::DB->new;
my $dao = $t->db;
my $db  = $dao->db;

my $user = $dao->create(User => {
    username  => 'stripe_params_user',
    email     => 'stripe_params@test.local',
    name      => 'Stripe Params User',
    user_type => 'parent',
});

my $payment = Registry::DAO::Payment->create($db, {
    user_id  => $user->id,
    amount   => 100.00,
    metadata => { tenant_slug => 'some_tenant', enrollment_items => [] },
});

my $captured;
{
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_payment_intent = sub {
        my ($self, $params) = @_;
        $captured = $params;
        return { id => 'pi_test_123', client_secret => 'cs_test' };
    };
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';
    $payment->create_payment_intent($db, { description => 'Test', receipt_email => 'a@b.c' });
}

ok $captured, 'stripe client received params';

# Every top-level value must be a plain scalar (no nested hashrefs).
for my $key (sort keys %$captured) {
    is ref($captured->{$key}), '', "param '$key' is a flat scalar (no nested refs)";
}

is $captured->{'metadata[payment_id]'}, $payment->id,
    'payment_id arrives as metadata[payment_id] bracket key';
is $captured->{'metadata[user_id]'}, $user->id,
    'user_id arrives as metadata[user_id] bracket key';
is $captured->{'metadata[tenant_slug]'}, 'some_tenant',
    'tenant_slug arrives as metadata[tenant_slug] bracket key';
ok !exists $captured->{metadata},
    'no nested metadata hashref remains';

# enrollment_items is a ref -- it must not appear as a bracket key in Stripe params
ok !exists $captured->{'metadata[enrollment_items]'},
    'ref-valued enrollment_items is excluded from Stripe metadata';

$t->cleanup_test_database;
done_testing;
