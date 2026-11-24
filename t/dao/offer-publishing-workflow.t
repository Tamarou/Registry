#!/usr/bin/env perl
# ABOUTME: The offer-publishing workflow, driven through the real WorkflowProcessor and step classes.
# ABOUTME: A tenant admin publishes an immutable, one-time-priced offer version for one of its own resources.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( import_all_workflows join_tenant );
use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::OfferVersion;
use Registry::Utility::WorkflowProcessor;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

import_all_workflows($dao);
Test::Registry::Fixtures::create_tenant( $dao, { name => 'Clay Studio', slug => 'clay_studio' } );
my $tenant_dao = Registry::DAO->new( url => $test_db->uri, schema => 'clay_studio' );
my $tdb        = $tenant_dao->db;
import_all_workflows($tenant_dao);

my $admin = Test::Registry::Fixtures::create_user( $dao,
    { username => 'clay_admin', name => 'Clay Admin', email => 'admin@clay.test', user_type => 'admin' } );
join_tenant( $dao, $admin, 'admin', 'clay_studio' );

my $seats = Test::Registry::Fixtures::create_resource( $tdb,
    { name => 'Wheel seats', kind => 'finite', capacity => 10 } );

# Starts a run of offer-publishing in $workflow_dao's schema as $user, then
# submits each step's fields in order. Returns the run.
sub walk ( $workflow_dao, $user, %by_step ) {
    my $workflow  = $workflow_dao->find( Workflow => { slug => 'offer-publishing' } );
    my $processor = Registry::WorkflowProcessor->new( dao => $workflow_dao );
    my $run       = $processor->new_run( $workflow, { user => { id => $user->id, name => $user->name } } );
    for my $slug (qw( offer-basics offer-price one-time-payment publish )) {
        my $step = $workflow->get_step( $workflow_dao->db, { slug => $slug } );
        $run->process( $workflow_dao->db, $step, $by_step{$slug} // {} );
    }
    return $run;
}

subtest 'admin publishes a one time priced offer version' => sub {
    walk( $tenant_dao, $admin,
        'offer-basics'     => { resource_id => $seats->id, offer_name => 'Couples wheel night' },
        'offer-price'      => { price_cents => 2500, currency => 'USD', units_per_acceptance => 2, per_booking_cap => 3 },
        'one-time-payment' => { one_time => 'offered' },
        'publish'          => { action => 'publish', refund => 'none' },
    );

    my @published = Registry::DAO::OfferVersion->find( $tdb, { published_at => { '!=' => undef } } );
    is scalar @published, 1, 'one published offer version in the tenant schema';
    my $v = $published[0] or return;
    is $v->resource_id,          $seats->id, 'it buys the chosen resource';
    is $v->price_cents,          2500,       'at the stated price';
    is $v->currency,             'usd',      'in the stated currency';
    is $v->units_per_acceptance, 2,          'two units per acceptance';
    is $v->per_booking_cap,      3,          'and a per-booking cap of three';
    is_deeply $v->payment_plans($tdb), [ { id => 'one_time', kind => 'one_time', fraction => undef } ],
        'paid for once';
    is_deeply $v->policies, { refund => { kind => 'none' } }, 'with an explicit none refund policy';
    is $tdb->query( 'SELECT o.name FROM offers o WHERE o.id = ?', $v->offer_id )->array->[0],
        'Couples wheel night', 'under the offer name given';

    my $ok = eval { $tdb->query( 'UPDATE offer_versions SET price_cents = 1 WHERE id = ?', $v->id ); 1 };
    ok !$ok, 'a direct UPDATE of the published version is refused by the database';
    like $@, qr/immutable once published/, 'as immutable';
};

done_testing;
