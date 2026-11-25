#!/usr/bin/env perl
# ABOUTME: An offer version may buy a set of resources (ADR 004 ruling (a)), immutable once published.
# ABOUTME: Every reader of what a version buys -- coverage, holds, guards, platform terms -- reads the set.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;

use Test::Registry::DB;
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO::Tenant;
use Registry::DAO::Resource;
use Registry::DAO::Offer;
use Registry::DAO::OfferVersion;
use Registry::DAO::Entitlement;
use Registry::Job::SendNotifications;
use Registry::PriceOps::PlatformTerms
    qw( platform_entitlement_terms platform_version_terms platform_offers_to_tenants );

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# The bootstrap seed's fixed ids.
my $SOLO         = '00000000-0000-0000-0002-000000000001';
my $SOLO_V1      = '00000000-0000-0000-0003-000000000001';
my $PAYMENTS     = '00000000-0000-0000-0001-000000000001';
my $EMAIL        = '00000000-0000-0000-0001-000000000002';
my $RUN_EVENTS   = '00000000-0000-0000-0001-000000000015';
my $RUN_SESSIONS = '00000000-0000-0000-0001-000000000014';
my $PAST         = '2020-01-01T00:00:00Z';

sub new_tenant ($slug) {
    my $tenant = Registry::DAO::Tenant->create( $db, { name => "Studio $slug", slug => $slug } );
    $db->query( 'SELECT clone_schema(dest_schema => ?)', $slug );
    return $tenant;
}

sub set_terms ( $resource_ids, %more ) {
    return offer_terms( undef, resource_ids => $resource_ids, %more );
}

sub ids ($resources) { [ sort map { $_->id } @$resources ] }

my $made = 0;
sub unbounded { Registry::DAO::Resource->create( $db, { name => 'set member ' . ++$made, kind => 'unbounded' } ) }

subtest 'a published version buys a set' => sub {
    my ( $a, $b ) = ( unbounded(), unbounded() );
    my $version = Registry::DAO::Offer->create( $db, { name => 'Bundle ' . ++$made } )
        ->draft( $db, set_terms( [ $a->id, $b->id ] ) )->publish($db);
    ok $version->is_published, 'published';
    is_deeply ids( $version->covered_resources($db) ), [ sort $a->id, $b->id ], 'covers each member';
    ok $version->buys( $db, $a->id ) && $version->buys( $db, $b->id ), 'buys each member';
    ok !$version->buys( $db, unbounded()->id ), 'and nothing else';
};

subtest 'a single resource version buys exactly its resource' => sub {
    my $one     = unbounded();
    my $version = Registry::DAO::Offer->create( $db, { name => 'Single ' . ++$made } )
        ->draft( $db, offer_terms( $one->id ) )->publish($db);
    is_deeply ids( $version->covered_resources($db) ), [ $one->id ], 'its one resource';
};

subtest 'the set is immutable once published' => sub {
    my ( $a, $b, $c ) = ( unbounded(), unbounded(), unbounded() );
    my $draft = Registry::DAO::Offer->create( $db, { name => 'Frozen ' . ++$made } )
        ->draft( $db, set_terms( [ $a->id, $b->id ] ) );
    lives_ok {
        $db->insert( 'offer_version_resources', { offer_version_id => $draft->id, resource_id => $c->id } );
        $db->delete( 'offer_version_resources', { offer_version_id => $draft->id, resource_id => $c->id } );
    } 'a draft set may change';

    $draft->publish($db);
    throws_ok {
        $db->insert( 'offer_version_resources', { offer_version_id => $draft->id, resource_id => $c->id } )
    } qr/published/, 'adding a member refused';
    throws_ok { $db->delete( 'offer_version_resources', { offer_version_id => $draft->id } ) }
        qr/published/, 'removing a member refused';
    throws_ok {
        $db->update( 'offer_version_resources', { resource_id => $c->id },
            { offer_version_id => $draft->id, resource_id => $a->id } )
    } qr/published/, 'swapping a member refused';
};

subtest 'a version buys one resource a class or a set never two' => sub {
    my $offer  = Registry::DAO::Offer->create( $db, { name => 'Mixed ' . ++$made } );
    my $single = $offer->draft( $db, offer_terms( unbounded()->id ) );
    throws_ok {
        $db->insert( 'offer_version_resources', { offer_version_id => $single->id, resource_id => unbounded()->id } )
    } qr/one resource or a class/, 'a set member on a one-resource version refused';

    my $nothing = Registry::DAO::Offer->create( $db, { name => 'Empty ' . ++$made } )
        ->draft( $db, set_terms( [] ) );
    throws_ok { $nothing->publish($db) } qr/buys nothing/, 'a version buying nothing is not published';
};

subtest 'tenant schema carries the set' => sub {
    my $tenant = new_tenant('set_studio');
    my $own    = $tenant->dao($dao)->db;
    my @r      = map { Registry::DAO::Resource->create( $own, { name => "own $_", kind => 'unbounded' } ) } 1, 2;
    my $v      = Registry::DAO::Offer->create( $own, { name => 'Own bundle' } )
        ->draft( $own, set_terms( [ map { $_->id } @r ] ) )->publish($own);
    is_deeply ids( $v->covered_resources($own) ), ids( \@r ), 'covered in the tenant schema';
    throws_ok { $own->delete( 'offer_version_resources', { offer_version_id => $v->id } ) }
        qr/published/, 'and immutable there';
};

# Solo v2 buys payment processing and a run right: the shape ruling (a) needs.
my $solo_v2;
subtest 'a set version is the platform offer to tenants' => sub {
    my $solo = Registry::DAO::Offer->find( $db, { id => $SOLO } );
    lives_ok {
        $solo_v2 = $solo->draft( $db, set_terms( [ $PAYMENTS, $RUN_EVENTS ], price_cents => 0,
            payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => 0.025 } ],
            policies      => { refund => { kind => 'keep_fee_with_admin_exception' } } ) )->publish($db);
    } 'retiring Solo v1 for a set v2 keeps a current platform offer';

    my ($offered) = grep { $_->{id} eq $solo_v2->id } platform_offers_to_tenants($db)->@*;
    ok $offered, 'the set version is offered to tenants';
    ok !grep( { $_->{id} eq $SOLO_V1 } platform_offers_to_tenants($db)->@* ), 'v1 no longer is';

    lives_and { cmp_ok platform_version_terms( $db, $solo_v2->id, 'revenue_share' )->{fraction}, '==', 0.025 }
        'its terms resolve by version';

    my $tx = $db->begin;
    throws_ok { $db->update( 'resources', { name => 'payments' }, { id => $PAYMENTS } ) }
        qr/keeps that name/, 'payment processing keeps its name while a set version sells it';
    undef $tx;
};

subtest 'an entitlement to a set version covers each member' => sub {
    my $tenant = new_tenant('bundle_holder');
    Registry::DAO::Entitlement->create( $db, {
        holder_tenant_id => $tenant->id, offer_version_id => $solo_v2->id,
        payment_plan_id  => 'revenue_share', starts_at => $PAST,
    } );
    ok( Registry::DAO::Tenant->holds( $db, $tenant->id, $_ ), "holds $_" )
        for 'payment processing', 'run:event-creation';
    ok !Registry::DAO::Tenant->holds( $db, $tenant->id, 'run:session-creation' ), 'not a non-member';
    lives_and { cmp_ok platform_entitlement_terms( $db, 'bundle_holder' )->{fraction}, '==', 0.025 }
        'its platform terms come from the set version';
};

subtest 'one platform term across set versions' => sub {
    my $tenant = new_tenant('two_terms');
    Registry::DAO::Entitlement->create( $db, {
        holder_tenant_id => $tenant->id, offer_version_id => $solo_v2->id,
        payment_plan_id  => 'revenue_share', starts_at => $PAST,
    } );
    my $other = Registry::DAO::Offer->create( $db, { name => 'Other platform bundle' } )->draft( $db,
        set_terms( [ $PAYMENTS, $RUN_SESSIONS ], price_cents => 0,
            payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => 0.03 } ] )
    )->publish($db);
    throws_ok {
        Registry::DAO::Entitlement->accept( $db, {
            holder_tenant_id => $tenant->id, offer_version_id => $other->id, payment_plan_id => 'revenue_share',
        } )
    } qr/already holds platform terms/, 'accept refuses a second set version with payment processing';
    throws_ok {
        Registry::DAO::Entitlement->create( $db, {
            holder_tenant_id => $tenant->id, offer_version_id => $other->id,
            payment_plan_id  => 'revenue_share', starts_at => $PAST,
        } )
    } qr/already holds an active platform entitlement/, 'and so does the database';
};

subtest 'one phase per offer across set versions' => sub {
    my $tenant = new_tenant('two_phases');
    my $offer  = Registry::DAO::Offer->create( $db, { name => 'Phased bundle' } );
    my $plan   = { payment_plans => [ { id => 'share', kind => 'percentage_of_sales', fraction => 0.01 } ] };
    my $v1 = $offer->draft( $db, set_terms( [ unbounded()->id, unbounded()->id ], %$plan ) )->publish($db);
    Registry::DAO::Entitlement->create( $db,
        { holder_tenant_id => $tenant->id, offer_version_id => $v1->id, payment_plan_id => 'share', starts_at => $PAST } );
    my $v2 = $offer->draft( $db, set_terms( [ unbounded()->id, unbounded()->id ], %$plan ) )->publish($db);
    throws_ok {
        Registry::DAO::Entitlement->create( $db,
            { holder_tenant_id => $tenant->id, offer_version_id => $v2->id, payment_plan_id => 'share', starts_at => $PAST } )
    } qr/exclu/i, 'an overlapping phase of the same offer refused';
};

subtest 'a set self offer is the platforms alone' => sub {
    my $tenant = new_tenant('not_the_platform');
    my $self   = Registry::DAO::Offer->create( $db, { name => 'Platform self bundle' } )->draft( $db,
        set_terms( [ unbounded()->id, unbounded()->id ], price_cents => 0,
            conditions => [ { kind => 'holder_is_offerer' } ] ) )->publish($db);
    throws_ok {
        Registry::DAO::Entitlement->create( $db,
            { holder_tenant_id => $tenant->id, offer_version_id => $self->id, payment_plan_id => 'pay', starts_at => $PAST } )
    } qr/holder_is_offerer/, 'a tenant may not hold it';
};

subtest 'email sending in a set lifts the cap' => sub {
    my $tenant = new_tenant('bundled_mail');
    ok defined Registry::Job::SendNotifications->send_allowance( $db, 'bundled_mail' ), 'capped at first';
    my $mail = Registry::DAO::Offer->create( $db, { name => 'Mail bundle' } )
        ->draft( $db, set_terms( [ $EMAIL, unbounded()->id ], price_cents => 0 ) )->publish($db);
    Registry::DAO::Entitlement->create( $db,
        { holder_tenant_id => $tenant->id, offer_version_id => $mail->id, payment_plan_id => 'pay', starts_at => $PAST } );
    ok !defined Registry::Job::SendNotifications->send_allowance( $db, 'bundled_mail' ), 'uncapped by the set';
};

subtest 'truncating a published set refused' => sub {
    throws_ok { $db->query('TRUNCATE offer_version_resources') }
        qr/cannot be truncated/, 'refused while a published version has a set';
    ok $db->query('SELECT count(*) FROM offer_version_resources')->array->[0], 'and every member stays';

    my $tenant = new_tenant('draft_sets_only');
    my $own    = $tenant->dao($dao)->db;
    my @r      = map { Registry::DAO::Resource->create( $own, { name => "draft $_", kind => 'unbounded' } ) } 1, 2;
    Registry::DAO::Offer->create( $own, { name => 'Draft bundle' } )->draft( $own, set_terms( [ map { $_->id } @r ] ) );
    lives_ok { $own->query('TRUNCATE offer_version_resources') } 'a schema with only draft sets may truncate';
};

# Pinned as it stands: a set's other members are where a change may move a
# seat. Day-one sets are unbounded run rights with no change policy, so
# nothing offers this yet; a set that sells seats revisits it.
subtest 'a set entitlements change targets are its other members' => sub {
    my $tenant = new_tenant('set_seats');
    my @seat   = map { Registry::DAO::Resource->create( $db, { name => "set seat $_", kind => 'finite', capacity => 4 } ) }
        1 .. 3;
    my $v = Registry::DAO::Offer->create( $db, { name => 'Seat bundle' } )
        ->draft( $db, set_terms( [ map { $_->id } @seat ], price_cents => 0 ) )->publish($db);
    my $held = Registry::DAO::Entitlement->grant( $db, {
        holder_tenant_id => $tenant->id, offer_version_id => $v->id, payment_plan_id => 'pay',
        starts_at        => $PAST,       resource_id      => $seat[1]->id, units => 1,
    } );
    is_deeply ids( $held->change_targets($db) ), ids( [ @seat[ 0, 2 ] ] ), 'the members it holds no unit of';

    my $unheld = Registry::DAO::Entitlement->create( $db, {
        holder_tenant_id => new_tenant('set_rights')->id, offer_version_id => $v->id,
        payment_plan_id  => 'pay', starts_at => $PAST,
    } );
    is_deeply ids( $unheld->change_targets($db) ), ids( \@seat ), 'every member when it holds no unit';
};

done_testing;
