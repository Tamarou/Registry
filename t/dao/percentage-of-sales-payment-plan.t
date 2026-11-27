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
use Registry::DAO::Entitlement;
use Registry::PriceOps::RevenueShare qw( revenue_share_fraction_for_tenant );

# A plan that is not instalments carries none of their fields.
my @NOT_INSTALMENTS = ( count => undef, cadence => undef, surcharge_pct => undef );

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
        [ { id => 'percentage_of_sales', kind => 'percentage_of_sales', fraction => '0.0250', @NOT_INSTALMENTS } ],
        'paid for by 2.5% of each sale, as the fraction 0.0250, and nothing else';

    refused( 'a rate finer than 4 fraction places', 'percentage-of-sales-payment', rate_percent => '2.50005' );
    refused( 'a rate above 100%',                   'percentage-of-sales-payment', rate_percent => '100.01' );
};

subtest 'holder revenue share read from the version' => sub {
    my $tenant = Test::Registry::Fixtures::create_tenant( $dao, { name => 'Solo Studio', slug => 'solo_studio' } );
    Registry::DAO::Entitlement->create( $db, {
        holder_tenant_id => $tenant->id,
        offer_version_id => $solo->id,
        payment_plan_id  => 'percentage_of_sales',
        starts_at        => '2020-01-01T00:00:00Z',
    } );
    is revenue_share_fraction_for_tenant( $db, 'solo_studio' ), '0.025',
        'the holder\'s revenue share is the published 2.5%';
};

subtest 'no payment plan publishes nothing' => sub {
    refused( 'declining every payment plan', 'publish', percentage_of_sales => 'declined' );
};

subtest 'empty rate stays with an error' => sub {
    refused( 'offering the plan with an empty rate', 'percentage-of-sales-payment', rate_percent => '' );
    refused( 'offering the plan with no rate',       'percentage-of-sales-payment', rate_percent => undef );
};

# The plans the version publishing %fields carries, a one-time plan beside.
sub plans_with (%fields) {
    return publish_solo( one_time => 'offered', %fields )->payment_plans($db);
}

subtest 'explicit zero rate distinct from declined' => sub {
    is_deeply plans_with( rate_percent => '0' ), [
        { id => 'one_time',            kind => 'one_time',            fraction => undef, @NOT_INSTALMENTS },
        { id => 'percentage_of_sales', kind => 'percentage_of_sales', fraction => '0.0000', @NOT_INSTALMENTS },
    ], 'an explicit 0% is a percentage plan with fraction 0';
    is_deeply plans_with( percentage_of_sales => 'declined' ),
        [ { id => 'one_time', kind => 'one_time', fraction => undef, @NOT_INSTALMENTS } ],
        'a declined plan is no percentage plan at all';
};

subtest 'invalid rate stays with an error' => sub {
    for my $rate ( '-1', '-0.5', '2.5%', 'abc', '100.01', '101', '2.50005', '2.505', '1e1', ' 2.5', '.5' ) {
        refused( "a rate of '$rate'", 'percentage-of-sales-payment', rate_percent => $rate );
    }
};

subtest 'two and a half percent stored exactly' => sub {
    my $version = publish_solo( rate_percent => '2.5' );
    my $stored  = $db->query( q{
        SELECT fraction::text, fraction = 0.025 FROM offer_version_payment_plans
         WHERE offer_version_id = ? AND kind = 'percentage_of_sales'
    }, $version->id )->array;
    is $stored->[0], '0.0250', 'stored as the decimal 0.0250';
    ok $stored->[1], 'which is exactly 0.025, not a binary-float neighbour';
    is plans_with( rate_percent => '100' )->[1]{fraction}, '1.0000', 'and 100% as exactly 1';
};

subtest 'declined plan with a rate writes nothing' => sub {
    is_deeply plans_with( percentage_of_sales => 'declined', rate_percent => '2.5' ),
        [ { id => 'one_time', kind => 'one_time', fraction => undef, @NOT_INSTALMENTS } ],
        'a rate beside a declined plan writes no percentage plan';
};

subtest 'tenant percentage offer changes no revenue share' => sub {
    my $shares = sub {
        my %share;
        for my $slug ( $db->query('SELECT slug FROM registry.tenants ORDER BY slug')->arrays->map( sub { $_->[0] } )->@* ) {
            $share{$slug} = eval { revenue_share_fraction_for_tenant( $db, $slug ) } // 'none';
        }
        \%share;
    };
    my $before = $shares->();

    Test::Registry::Fixtures::create_tenant( $dao, { name => 'Clay Studio', slug => 'clay_studio' } );
    my $clay = Test::Registry::Fixtures::create_user( $dao,
        { username => 'clay_admin', name => 'Clay Admin', email => 'admin@clay.test', user_type => 'admin' } );
    join_tenant( $dao, $clay, 'admin', 'clay_studio' );
    my $cdb = Registry::DAO->new( url => $test_db->uri, schema => 'clay_studio' )->db;
    import_all_workflows( Registry::DAO->new( url => $test_db->uri, schema => 'clay_studio' ) );
    # Named like the platform's own resource, in the tenant's schema.
    my $own = Test::Registry::Fixtures::create_resource( $cdb, { name => 'payment processing', kind => 'unbounded' } );

    my $version = publish_offer( $dao, 'clay_studio', $clay, {
        'offer-basics' => { resource_id => $own->id, offer_name => 'Clay share' },
        'offer-price'  => { price_cents => 0, currency => 'usd', units_per_acceptance => 1, per_booking_cap => 1 },
        one_time            => 'declined',
        percentage_of_sales => 'offered',
        rate_percent        => '1',
    } );
    is $version->payment_plans($cdb)->[0]{fraction}, '0.0100', 'the tenant publishes its 1% offer';

    my $after = $shares->();
    is delete $after->{clay_studio}, 'none', 'the publisher itself gains no revenue share';
    is_deeply $after, $before, 'and no tenant\'s resolved revenue share changes';
    is $after->{solo_studio}, '0.025', 'the Solo test holder still pays 2.5%';
};

done_testing;
