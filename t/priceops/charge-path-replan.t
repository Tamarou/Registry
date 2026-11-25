#!/usr/bin/env perl
# ABOUTME: The charge path re-reads the chosen offer version instead of trusting run data.
# ABOUTME: A run whose chosen version was superseded or withdrawn is never charged that version's price.

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::Offer;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

$dao->import_workflows(['workflows/tenant-signup.yml']);
my $workflow = $dao->find( Workflow => { slug => 'tenant-signup' } );
# The commit point: no payment page any more, so the review button is what
# resolves the plan and provisions. Same class, same resolver.
my $payment  = Registry::DAO::WorkflowStep->find( $db,
    { workflow_id => $workflow->id, slug => 'review' } );
ok $payment, 'the signup commit step exists' or BAIL_OUT 'workflow shape changed';

# A platform offer to tenants at its own rate, so a stale rate would show.
# No monthly base: signup lists no offer it would need a card for.
sub kiln_terms ($fraction) {
    return offer_terms( '00000000-0000-0000-0001-000000000001',
        price_cents   => 0,
        payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => $fraction } ],
    );
}
my $kiln = Registry::DAO::Offer->create( $db, { name => 'Kiln Share' } );
my $v1   = $kiln->draft( $db, kiln_terms(0.03) )->publish($db);

# A run that carries a chosen version, exactly as the review step stores it.
sub run_having_chosen ($version_id) {
    my $run = $workflow->new_run($db);
    $run->update_data( $db, { selected_offer_version => $version_id } );
    return $run;
}

subtest 'a current choice is used' => sub {
    my $config = $payment->get_subscription_config( $db, run_having_chosen( $v1->id ) );
    is $config->{plan_name}, 'Kiln Share', 'the chosen offer is what gets configured';
    is $config->{revenue_share_percent}, 3, 'at its version rate';
};

# The case with no adversary in it: a signup started before a price change and
# resumed after it. The run carries a version id, never a rate, and a
# superseded version is not one anybody can be charged.
subtest 'a superseded choice is not charged' => sub {
    my $run = run_having_chosen( $v1->id );
    $kiln->draft( $db, kiln_terms(0.04) )->publish($db);

    isnt $payment->get_subscription_config( $db, $run )->{revenue_share_percent}, 3,
        'the superseded rate is not what would be charged';
    my $result = $payment->process( $db, {}, $run );
    like "@{ $result->{errors} // [] }", qr/choose one of the plans/i,
        'and the commit refuses until a current plan is chosen';
};

subtest 'a withdrawn offer is not charged' => sub {
    my $current = $kiln->current_version($db);
    my $run = run_having_chosen( $current->id );
    $db->query( 'UPDATE registry.offer_versions SET superseded_at = now() WHERE id = ?', $current->id );

    isnt $payment->get_subscription_config( $db, $run )->{revenue_share_percent}, 4,
        'the withdrawn offer is not what would be charged';
    my $result = $payment->process( $db, {}, $run );
    like "@{ $result->{errors} // [] }", qr/choose one of the plans/i, 'and the commit refuses';
};

done_testing;
