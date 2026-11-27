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
use Registry::DAO::Entitlement;

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

subtest 'an instalment count below two is refused' => sub {
    throws_ok { draft_with( instalment_plan( count => 1 ) ) } qr/count/;
};

subtest 'an unknown cadence is refused' => sub {
    throws_ok { draft_with( instalment_plan( cadence => 'daily' ) ) } qr/cadence/;
};

subtest 'a surcharge with more than two places is refused' => sub {
    throws_ok { draft_with( instalment_plan( surcharge_pct => '1.234' ) ) } qr/surcharge/;
};

subtest 'instalment fields on a one_time plan are refused' => sub {
    throws_ok {
        Registry::DAO::OfferVersion->draft( $db, new_offer(),
            offer_terms( $r->id, payment_plans => [ { id => 'pay', kind => 'one_time', count => 3 } ] ) )
    } qr/instalments/;
};

subtest 'publishing instalments without a missed_payment policy is refused' => sub {
    my $v = draft_without_missed_payment();
    throws_ok { $v->publish($db) } qr/no missed_payment policy/;
    unlike $@, qr/DBD::Pg/, "refused by the DAO, before the database is asked";
    ok !$db->select( 'offer_versions', ['published_at'], { id => $v->id } )->hash->{published_at},
        'and it stays a draft';
};

subtest 'the database refuses publishing instalments without missed_payment' => sub {
    my $bare = draft_without_missed_payment();
    throws_ok { $db->query( 'UPDATE offer_versions SET published_at = now() WHERE id = ?', $bare->id ) }
        qr/missed_payment/;
};

subtest 'a child holds two sessions of one offer on instalments' => sub {
    my $parent = $db->insert( 'users', { username => 'instalment_parent' }, { returning => 'id' } )->hash->{id};
    my $kid    = $db->insert( 'family_members',
        { family_id => $parent, child_name => 'Kit', birth_date => '2018-05-01' }, { returning => 'id' } )->hash->{id};
    my @sessions = map { Registry::DAO::Resource->create( $db, { name => "Camp week $_", kind => 'finite', capacity => 20 } ) } 1, 2;
    my $v = Registry::DAO::OfferVersion->draft( $db, new_offer(), offer_terms( undef,
        resource_ids  => [ map { $_->id } @sessions ],
        payment_plans => [ instalment_plan() ],
        policies      => { refund => { kind => 'none' }, missed_payment => { kind => 'keep_and_owe' } } ) )->publish($db);
    my $buy = sub ($session) {
        Registry::DAO::Entitlement->grant( $db, {
            holder_family_member_id => $kid,  payer_user_id   => $parent,
            offer_version_id        => $v->id, payment_plan_id => 'parts',
            starts_at => '2027-06-01T00:00:00Z', resource_id => $session->id, units => 1,
        } );
    };
    lives_ok { $buy->( $sessions[0] ) } 'the first session';
    lives_ok { $buy->( $sessions[1] ) } 'and the second, both in effect at once';
};

done_testing;
