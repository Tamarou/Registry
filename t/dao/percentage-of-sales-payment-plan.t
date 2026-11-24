#!/usr/bin/env perl
# ABOUTME: offer-publishing's percentage-of-sales payment plan, driven through the real WorkflowProcessor.
# ABOUTME: The rate is an exact 4-place fraction, an offer must carry some plan, and a holder's revenue share reads it.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( import_all_workflows join_tenant publish_offer );
use Registry::DAO;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
import_all_workflows($dao);

# The bootstrap's unbounded resource the platform's revenue share buys.
my $PAYMENT_PROCESSING = '00000000-0000-0000-0001-000000000001';

my $alex = Test::Registry::Fixtures::create_user( $dao,
    { username => 'alex', name => 'Alex', email => 'alex@registry.test', user_type => 'admin' } );
join_tenant( $dao, $alex, 'admin' );

# Publishes a $0 payment-processing offer as registry's admin with no one-time
# plan, the given top-level fields overriding. Dies naming a refusing step.
sub publish_solo (%fields) {
    state $n = 0;
    $n++;
    return publish_offer( $dao, 'registry', $alex, {
        'offer-basics' => { resource_id => $PAYMENT_PROCESSING, offer_name => "Solo test $n" },
        'offer-price'  => { price_cents => 0, currency => 'usd', units_per_acceptance => 1, per_booking_cap => 1 },
        one_time            => 'declined',
        percentage_of_sales => 'offered',
        %fields,
    } );
}

sub counts { $db->query('SELECT (SELECT count(*) FROM offers), (SELECT count(*) FROM offer_versions)')->array }

# Asserts publishing with %fields is refused by $step and creates nothing.
sub refused ( $label, $step, %fields ) {
    my $before = counts();
    my $ok     = eval { publish_solo(%fields); 1 };
    ok !$ok, "$label is refused";
    like $@, qr/\Q$step\E refused/, "by $step";
    is_deeply counts(), $before, 'and creates nothing';
}

my $solo;
subtest 'admin publishes a percentage of sales plan' => sub {
    $solo = publish_solo( rate_percent => '2.5' );
    ok $solo->is_published, 'the offer publishes';
    is $solo->price_cents, 0, 'for $0';
    is_deeply $solo->payment_plans($db),
        [ { id => 'percentage_of_sales', kind => 'percentage_of_sales', fraction => '0.0250' } ],
        'paid for by 2.5% of each sale, as the fraction 0.0250, and nothing else';

    refused( 'a rate finer than 4 fraction places', 'percentage-of-sales-payment', rate_percent => '2.50005' );
    refused( 'a rate above 100%',                   'percentage-of-sales-payment', rate_percent => '100.01' );
};

subtest 'no payment plan publishes nothing' => sub {
    refused( 'declining every payment plan', 'publish', percentage_of_sales => 'declined' );
};

done_testing;
