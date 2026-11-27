#!/usr/bin/env perl
# ABOUTME: Instalments are a payment plan kind beside one_time: a count, a cadence and an optional surcharge.
# ABOUTME: A version offering them is published only with a missed_payment policy, refused by the DAO and the database.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Test::Registry::DB;
use Test::Registry::Offers qw( offer_terms instalment_plan );
use Registry::DAO::Resource;
use Registry::DAO::Offer;
use Registry::DAO::OfferVersion;

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;

my $r = Registry::DAO::Resource->create( $db, { name => 'Camp week', kind => 'finite', capacity => 20 } );

my $n = 0;
sub new_offer () { Registry::DAO::Offer->create( $db, { name => 'Camp ' . ++$n } )->id }

# A draft offering $plan beside one_time, with a missed_payment policy.
sub draft_with ($plan) {
    return Registry::DAO::OfferVersion->draft( $db, new_offer(), offer_terms( $r->id,
        payment_plans => [ { id => 'pay', kind => 'one_time' }, $plan ],
        policies      => { refund => { kind => 'none' }, missed_payment => { kind => 'keep_and_owe' } } ) );
}

# A draft offering instalments with no missed_payment policy.
sub draft_without_missed_payment () {
    return Registry::DAO::OfferVersion->draft( $db, new_offer(),
        offer_terms( $r->id, payment_plans => [ instalment_plan() ] ) );
}

subtest 'an instalments plan is drafted, listed and published' => sub {
    my $v = draft_with( instalment_plan( cadence => 'weekly', surcharge_pct => '5.00' ) );
    my $plans = $v->payment_plans($db);
    is_deeply [ map { $_->{kind} } @$plans ], [qw( instalments one_time )], 'listed by id';
    is_deeply { $plans->[0]->%{qw( id count cadence )} }, { id => 'parts', count => 3, cadence => 'weekly' },
        'with its count and cadence';
    is $plans->[0]{surcharge_pct} + 0, 5, 'and its surcharge';
    ok $v->publish($db)->is_published, 'published';
};

done_testing;
