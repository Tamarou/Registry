#!/usr/bin/env perl
# ABOUTME: Entitlements: who holds what, who paid, under which stamped offer version and plan, and when.
# ABOUTME: The database enforces the stamp and its integrity, so raw SQL is held to it as much as the DAO.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Test::Registry::DB;
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO::Resource;
use Registry::DAO::Offer;
use Registry::DAO::OfferVersion;
use Registry::DAO::Entitlement;
use Registry::DAO::Tenant;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# A tenant provisioned the way signup provisions one: the row, then its schema.
sub new_tenant ($slug) {
    my $tenant = Registry::DAO::Tenant->create( $db, { name => "Studio $slug", slug => $slug } );
    $db->query( 'SELECT clone_schema(dest_schema => ?)', $slug );
    return $tenant->dao($dao)->db;
}

# A person in $handle's schema; returns their id.
sub person ( $handle, $name ) {
    return $handle->insert( 'users', { username => $name }, { returning => 'id' } )->hash->{id};
}

# A child in $handle's schema whose family is $parent_id; returns its id.
sub child ( $handle, $parent_id, $name ) {
    return $handle->insert( 'family_members',
        { family_id => $parent_id, child_name => $name, birth_date => '2018-05-01' },
        { returning => 'id' } )->hash->{id};
}

# A published version 1 of a new offer in $handle's schema.
sub published_version ( $handle, $name ) {
    my $resource = Registry::DAO::Resource->create( $handle,
        { name => "$name seats", kind => 'finite', capacity => 10 } );
    my $offer = Registry::DAO::Offer->create( $handle, { name => $name } );
    return $offer->draft( $handle, offer_terms( $resource->id ) )->publish($handle);
}

my $studio = new_tenant('wheel_house');
my $START  = '2026-12-01T00:00:00Z';

subtest 'person held entitlement records its stamp' => sub {
    my $sam     = person( $studio, 'sam' );
    my $version = published_version( $studio, 'Drop-in wheel' );

    my $e = Registry::DAO::Entitlement->create( $studio, {
        holder_user_id   => $sam,
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
        starts_at        => $START,
    } );

    my $read = Registry::DAO::Entitlement->find( $studio, { id => $e->id } );
    is $read->holder_user_id,   $sam,         'it records its holder';
    is $read->offer_version_id, $version->id, 'the exact offer version';
    is $read->payment_plan_id,  'pay',        'and the accepted payment plan';
    ok !Registry::DAO::Entitlement->find( $db, { id => $e->id } ),
        'and lives in the tenant schema, not registry';
};

subtest 'child holder with separate payer found by either' => sub {
    my $parent  = person( $studio, 'pat' );
    my $kid     = child( $studio, $parent, 'Kit' );
    my $version = published_version( $studio, 'After-school art' );

    my $e = Registry::DAO::Entitlement->create( $studio, {
        holder_family_member_id => $kid,
        payer_user_id           => $parent,
        offer_version_id        => $version->id,
        payment_plan_id         => 'pay',
        starts_at               => $START,
    } );

    is_deeply [ map { $_->id } Registry::DAO::Entitlement->held_by( $studio, $kid ) ], [ $e->id ],
        'entitlements held for the child find it';
    is_deeply [ map { $_->id } Registry::DAO::Entitlement->paid_by( $studio, $parent ) ], [ $e->id ],
        'entitlements paid for by the parent find it';
    is_deeply [ Registry::DAO::Entitlement->held_by( $studio, $parent ) ], [],
        'the parent paid but holds nothing';
};

subtest 'tenant holds a platform offer version' => sub {
    my $tenant  = Registry::DAO::Tenant->create( $db, { name => 'Clay Co', slug => 'clay_co' } );
    my $version = published_version( $db, 'Solo' );

    my $e = Registry::DAO::Entitlement->create( $db, {
        holder_tenant_id => $tenant->id,
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
        starts_at        => $START,
    } );

    is_deeply [ map { $_->id } Registry::DAO::Entitlement->held_by( $db, $tenant->id ) ], [ $e->id ],
        'the platform finds the entitlement by its tenant holder';
    is Registry::DAO::Entitlement->find( $db, { id => $e->id } )->holder_tenant_id, $tenant->id,
        'and records the tenant as its holder';
};

subtest 'holder kind and payment plan integrity enforced' => sub {
    my $sam     = person( $studio, 'sam2' );
    my $kid     = child( $studio, $sam, 'Kai' );
    my $version = published_version( $studio, 'Glaze night' );
    {
        my $resource = Registry::DAO::Resource->create( $studio,
            { name => 'Glaze seats', kind => 'finite', capacity => 4 } );
        Registry::DAO::Offer->create( $studio, { name => 'Monthly glaze' } )->draft( $studio,
            offer_terms( $resource->id, payment_plans => [ { id => 'monthly', kind => 'one_time' } ] ) )
            ->publish($studio);
    }
    my %stamp = ( offer_version_id => $version->id, payment_plan_id => 'pay', starts_at => $START );

    throws_ok { Registry::DAO::Entitlement->create( $studio, {%stamp} ) }
        qr/entitlements_one_holder/, 'an entitlement with no holder is refused';
    throws_ok {
        Registry::DAO::Entitlement->create( $studio,
            { %stamp, holder_user_id => $sam, holder_family_member_id => $kid } )
    } qr/entitlements_one_holder/, 'an entitlement with two holders is refused';
    throws_ok {
        Registry::DAO::Entitlement->create( $studio,
            { %stamp, holder_user_id => $sam, payment_plan_id => 'monthly' } )
    } qr/entitlements_payment_plan_fkey/,
        "another offer version's plan is refused";
    throws_ok {
        Registry::DAO::Entitlement->create( $studio,
            { %stamp, holder_user_id => $sam, payment_plan_id => 'nope' } )
    } qr/entitlements_payment_plan_fkey/, 'a plan that does not exist is refused';
};

subtest 'in effect lookup keeps the sold under version' => sub {
    my $sam     = person( $studio, 'sam3' );
    my $v1      = published_version( $studio, 'Winter term' );
    my $e = Registry::DAO::Entitlement->create( $studio, {
        holder_user_id   => $sam,
        offer_version_id => $v1->id,
        payment_plan_id  => 'pay',
        starts_at        => '2026-12-01T00:00:00Z',
        ends_at          => '2027-01-01T00:00:00Z',
    } );

    ok $studio->query(
        'SELECT in_effect = tstzrange(?, ?) FROM entitlements WHERE id = ?',
        '2026-12-01T00:00:00Z', '2027-01-01T00:00:00Z', $e->id )->array->[0],
        'its in-effect period is recorded';

    my $found = sub ($t) {
        [ map { $_->id } Registry::DAO::Entitlement->in_effect_at( $studio, $t, { holder_user_id => $sam } ) ];
    };
    is_deeply $found->('2026-12-15T12:00:00Z'), [ $e->id ], 'in effect inside its period';
    is_deeply $found->('2026-11-30T12:00:00Z'), [],         'not before it';
    is_deeply $found->('2027-01-15T12:00:00Z'), [],         'nor after it';

    my $v2 = Registry::DAO::Offer->find( $studio, { id => $v1->offer_id } )
        ->draft( $studio, offer_terms( $v1->resource_id, price_cents => 2500 ) )->publish($studio);
    ok defined Registry::DAO::OfferVersion->find( $studio, { id => $v1->id } )->superseded_at,
        'its offer version is superseded';

    my $read = Registry::DAO::Entitlement->find( $studio, { id => $e->id } );
    is $read->offer_version_id, $v1->id, 'the entitlement still names the version it was sold under';
    is $read->offer_version($studio)->price_cents, 2000, 'and reads that version\'s terms';
    isnt $v2->price_cents, 2000, 'not the new version\'s';
};

done_testing;
