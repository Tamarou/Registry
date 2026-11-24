#!/usr/bin/env perl
# ABOUTME: offer-publishing run for an existing offer appends version N+1 and supersedes N in one transaction.
# ABOUTME: Old versions and their entitlements stay untouched; stale, concurrent and foreign choices are refused.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use POSIX ();
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( import_all_workflows join_tenant publish_offer );
use Registry::DAO;
use Registry::DAO::Entitlement;
use Registry::DAO::Offer;
use Registry::DAO::OfferVersion;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowSteps::TenantPayment;
use Registry::Utility::WorkflowProcessor;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
import_all_workflows($dao);

my %tenant_dao;
for my $slug (qw( clay_studio glaze_house )) {
    Test::Registry::Fixtures::create_tenant( $dao, { name => $slug, slug => $slug } );
    $tenant_dao{$slug} = Registry::DAO->new( url => $test_db->uri, schema => $slug );
    import_all_workflows( $tenant_dao{$slug} );
}
my $tdb = $tenant_dao{clay_studio}->db;

my $admin = Test::Registry::Fixtures::create_user( $dao,
    { username => 'clay_admin', name => 'Clay Admin', email => 'admin@clay.test', user_type => 'admin' } );
join_tenant( $dao, $admin, 'admin', $_ ) for qw( clay_studio glaze_house registry );

my $seats = Test::Registry::Fixtures::create_resource( $tdb,
    { name => 'Wheel seats', kind => 'finite', capacity => 10 } );

sub basics (%more) { ( 'offer-basics' => { resource_id => $seats->id, offer_name => 'Wheel class', %more } ) }

sub price ($cents) {
    ( 'offer-price' => { price_cents => $cents, currency => 'usd', units_per_acceptance => 1, per_booking_cap => 1 } );
}

# The helper's neutral answers, for runs this file stops short of publishing.
my %DEFAULTS = (
    resource_mode => 'existing', one_time => 'offered', percentage_of_sales => 'declined',
    refund => 'none', change => 'none', use => 'none', expiry => 'never',
);

# Walks a run in $slug up to, not through, the step $stop; returns the run and
# that step, so a test chooses when it is answered.
sub run_to ( $stop, $slug, %terms ) {
    my $tdao     = $tenant_dao{$slug};
    my $workflow = $tdao->find( Workflow => { slug => 'offer-publishing' } );
    my $run      = Registry::WorkflowProcessor->new( dao => $tdao )
        ->new_run( $workflow, { user => { id => $admin->id, name => $admin->name } } );
    my $step = $workflow->first_step( $tdao->db );
    for ( ; $step->slug ne $stop ; $step = $step->next_step( $tdao->db ) ) {
        my $result = $run->process( $tdao->db, $step, { %DEFAULTS, ( $terms{ $step->slug } // {} )->%* } );
        die sprintf "%s refused: %s\n", $step->slug, join '; ', $result->{errors}->@* if $result->{errors};
    }
    return ( $run, $step );
}

sub current_versions ( $offer_id, $db = $tdb ) {
    return $db->query( q{
        SELECT array_agg(version ORDER BY version) FROM offer_versions
         WHERE offer_id = ? AND published_at IS NOT NULL AND superseded_at IS NULL
    }, $offer_id )->array->[0] // [];
}

sub row_of ($id) { $tdb->query( 'SELECT * FROM offer_versions WHERE id = ?', $id )->hash }

my $v1 = publish_offer( $dao, 'clay_studio', $admin, { basics(), price(2500) } );

subtest 'new version supersedes and keeps the old one' => sub {
    my $before      = row_of( $v1->id );
    my $buyer = Test::Registry::Fixtures::create_user( $tdb,
        { username => 'potter', name => 'Potter', email => 'potter@clay.test', user_type => 'parent' } );
    my $entitlement = Registry::DAO::Entitlement->create( $tdb, {
        holder_user_id   => $buyer->id,
        offer_version_id => $v1->id,
        payment_plan_id  => 'one_time',
        starts_at        => '2026-01-01T00:00:00Z',
    } );

    my ($run) = run_to( 'offer-price', 'clay_studio', basics( offer_id => $v1->offer_id ) );
    is_deeply $run->data->{offer_price},
        { price_cents => 2500, currency => 'usd', units_per_acceptance => 1, per_booking_cap => 1 },
        'choosing the offer pre-fills the walk from its current version';

    my $v2 = publish_offer( $dao, 'clay_studio', $admin,
        { basics( offer_id => $v1->offer_id ), price(3000) } );
    is $v2->offer_id, $v1->offer_id, 'the new version belongs to the same offer';
    is $v2->version,  2,             'as version 2';
    is_deeply current_versions( $v1->offer_id ), [2], 'exactly one version is current, the new one';
    is( Registry::DAO::Offer->find( $tdb, { id => $v1->offer_id } )->current_version($tdb)->price_cents,
        3000, 'at the new price' );

    my $after = row_of( $v1->id );
    ok defined $after->{superseded_at}, 'v1 is superseded';
    delete $_->{superseded_at} for $before, $after;
    is_deeply $after, $before, 'and otherwise unchanged';
    is( Registry::DAO::Entitlement->find( $tdb, { id => $entitlement->id } )->offer_version_id,
        $v1->id, 'the entitlement sold under v1 still names v1' );
};

subtest 'foreign or missing offer id stays with an error' => sub {
    my $foreign = publish_offer( $dao, 'glaze_house', $admin, {
        'offer-basics' => { resource_id => Test::Registry::Fixtures::create_resource(
            $tenant_dao{glaze_house}->db, { name => 'Kiln', kind => 'finite', capacity => 2 } )->id,
            offer_name => 'Kiln share' },
        price(800),
    } );
    my $solo = '00000000-0000-0000-0002-000000000001';    # registry's Solo offer
    for my $case (
        [ $foreign->offer_id,                     "another tenant's offer" ],
        [ $solo,                                  "the platform's Solo, from a tenant host" ],
        [ '6f1b3c1e-0000-4000-8000-000000000000', 'a nonexistent offer' ],
        [ 'not-a-uuid',                           'a malformed id' ],
    ) {
        my $ok = eval { run_to( 'publish', 'clay_studio', basics( offer_id => $case->[0] ), price(100) ); 1 };
        ok !$ok, "$case->[1] is refused";
        like $@, qr/\Aoffer-basics refused: Choose one of your published offers/, 'at offer-basics';
    }
    is_deeply current_versions( $foreign->offer_id, $tenant_dao{glaze_house}->db ), [1],
        "the other tenant's offer is untouched";
};

subtest 'stale run never edits the newer version' => sub {
    my $offer_id = $v1->offer_id;
    my ( $stale, $publish ) = run_to( 'publish', 'clay_studio', basics( offer_id => $offer_id ), price(4000) );
    my $newer = publish_offer( $dao, 'clay_studio', $admin, { basics( offer_id => $offer_id ), price(3500) } );
    my $before = row_of( $newer->id );

    my $result = $stale->process( $tdb, $publish, { action => 'publish' } );
    like join( ';', ( $result->{errors} // [] )->@* ), qr/newer version/, 'the stale run stays with an error';
    is_deeply row_of( $newer->id ), $before, 'the newer version is not touched';
    is_deeply current_versions($offer_id), [ $newer->version ], 'and it is the one current version';
};

subtest 'concurrent new versions leave one current' => sub {
    my $offer_id = $v1->offer_id;
    my ( $run_a, $publish ) = run_to( 'publish', 'clay_studio', basics( offer_id => $offer_id ), price(5000) );
    my ($run_b) = run_to( 'publish', 'clay_studio', basics( offer_id => $offer_id ), price(5100) );

    # Two real connections and a fork: A holds its publish open while B starts.
    my $uri = $test_db->uri;
    pipe( my $child_reads, my $parent_writes ) or die "pipe: $!";
    my $pid = fork() // die "fork: $!";
    unless ($pid) {
        close $parent_writes;
        readline $child_reads;
        my $bdao   = Registry::DAO->new( url => $uri, schema => 'clay_studio' );
        my $result = eval {
            $bdao->find( WorkflowRun => { id => $run_b->id } )->process( $bdao->db, $publish, { action => 'publish' } );
        };
        print STDERR "child publish died: $@" unless $result;
        POSIX::_exit( $result && $result->{errors} && !$result->{published_offer_version_id} ? 0 : 1 );
    }
    close $child_reads;
    my $adao = Registry::DAO->new( url => $uri, schema => 'clay_studio' );
    my $adb  = $adao->db;
    my $tx   = $adb->begin;
    my $a    = $adao->find( WorkflowRun => { id => $run_a->id } )->process( $adb, $publish, { action => 'publish' } );
    print $parent_writes "go\n";
    $parent_writes->flush;
    sleep 1;    # let B reach the offer and wait behind A
    $tx->commit;
    waitpid $pid, 0;

    ok $a->{published_offer_version_id}, 'the first run publishes';
    is $? >> 8, 0, 'the losing run stays with an error';
    my $won = Registry::DAO::OfferVersion->find( $tdb, { id => $a->{published_offer_version_id} } );
    is_deeply current_versions($offer_id), [ $won->version ], 'exactly one version is current, the winner';
    is $won->price_cents, 5000, "at the winner's price";
};

subtest 'failed publish leaves the old version current' => sub {
    my $offer_id = $v1->offer_id;
    my $current  = Registry::DAO::Offer->find( $tdb, { id => $offer_id } )->current_version($tdb);
    my $count    = scalar Registry::DAO::Offer->find( $tdb, { id => $offer_id } )->versions($tdb)->@*;
    my ( $run, $publish ) = run_to( 'publish', 'clay_studio', basics( offer_id => $offer_id ), price(6000) );

    # A database error after the new version is appended, at its publishing.
    $tdb->query( q{
        CREATE FUNCTION fail_publish() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN RAISE EXCEPTION 'forced publish failure'; END $$
    } );
    $tdb->query( q{
        CREATE TRIGGER fail_publish BEFORE UPDATE ON offer_versions FOR EACH ROW
         WHEN (OLD.published_at IS NULL AND NEW.published_at IS NOT NULL) EXECUTE FUNCTION fail_publish()
    } );
    my $result = $run->process( $tdb, $publish, { action => 'publish' } );
    $tdb->query('DROP TRIGGER fail_publish ON offer_versions');
    $tdb->query('DROP FUNCTION fail_publish()');

    like join( ';', ( $result->{errors} // [] )->@* ), qr/forced publish failure/, 'the run stays with the error';
    is_deeply current_versions($offer_id), [ $current->version ], 'the old version is still the current one';
    is scalar Registry::DAO::Offer->find( $tdb, { id => $offer_id } )->versions($tdb)->@*, $count,
        'and no new version, draft or published, is left behind';
};

subtest 'signup resolves one platform offer after a new solo version' => sub {
    my $rdb = $dao->db;
    my %platform = (
        'offer-basics'                => { resource_id => '00000000-0000-0000-0001-000000000001' },
        'one-time-payment'            => { one_time => 'declined' },
        'percentage-of-sales-payment' => { percentage_of_sales => 'offered', rate_percent => '2.4' },
        price(0),
    );
    my $solo = publish_offer( $dao, 'registry', $admin, { %platform,
        'offer-basics' => { $platform{'offer-basics'}->%*, offer_id => '00000000-0000-0000-0002-000000000001' },
        refund => 'keep_fee_with_admin_exception' } );
    # The platform's 0% offer to itself, which must stay restricted to itself.
    my $own = publish_offer( $dao, 'registry', $admin, { %platform,
        'offer-basics'                => { $platform{'offer-basics'}->%*, offer_id => '00000000-0000-0000-0002-000000000002' },
        'percentage-of-sales-payment' => { percentage_of_sales => 'offered', rate_percent => '0' } } );
    is_deeply $own->conditions, [ { kind => 'holder_is_offerer' } ], 'a new version keeps its conditions';

    my $signup = Registry::DAO::WorkflowSteps::TenantPayment->new(
        id => $solo->id, slug => 'payment', workflow_id => $solo->id, description => '',
        class => 'Registry::DAO::WorkflowSteps::TenantPayment' );
    is $signup->_platform_offer_to_tenants($rdb)->{offer_version_id}, $solo->id,
        'signup finds exactly one platform offer to tenants: the new Solo version';
};

done_testing;
