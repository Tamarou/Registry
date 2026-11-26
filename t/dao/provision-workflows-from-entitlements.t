#!/usr/bin/env perl
# ABOUTME: A tenant made by signup holds copies of exactly the workflows its accepted Solo version grants run rights to.
# ABOUTME: Provisioning copies nothing else: no copy-everything loop, no slug skips, all or nothing.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More;

use Mojo::Home;
use Registry::DAO qw(Workflow);
use Registry::DAO::Entitlement;
use Registry::DAO::Template;
use Registry::DAO::Tenant;
use Registry::WorkflowDivergence;
use Test::Registry::DB;
use Test::Registry::Helpers qw(import_all_workflows platform_solo_offer_version_id);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

import_all_workflows($dao);
Registry::DAO::Template->import_from_file( $dao, $_ )
  for Mojo::Home->new->child('templates')->list_tree->grep(qr/\.html\.ep$/)->each;

# Signup's checkout step makes no Stripe call on Solo's $0 base.
local $ENV{STRIPE_PUBLISHABLE_KEY};
local $ENV{STRIPE_SECRET_KEY};

# Walks tenant-signup as a visitor does, accepting Solo's current version.
# Returns the run, its review step's last result, and the tenant made (or undef).
my $made = 0;
sub sign_up ($slug) {
    my $run = $dao->find( Workflow => { slug => 'tenant-signup' } )->new_run($db);
    $run->process( $db, $run->next_step($db), {} );
    $run->process( $db, $run->next_step($db), { slug => $slug, name => "Studio $slug" } );
    $run->process( $db, $run->next_step($db),
        { users => [ { username => "${slug}_owner", password => 'pw' . ++$made } ] } );
    my $offer = eval { platform_solo_offer_version_id($dao) } // '';
    my $review = $run->process( $db, $run->next_step($db), { terms_accepted => 1, offer_version => $offer } );
    return ( $run, $review, Registry::DAO::Tenant->find( $db, { slug => $slug } ) );
}

sub slugs_in ($schema) {
    return [ sort map { $_->{slug} } $dao->connect_schema($schema)->db->select( 'workflows', ['slug'] )->hashes->each ];
}

sub granted_to ($tenant) {
    return [ sort grep {
        Registry::DAO::Entitlement->may_run( $db, $tenant->id, $_ ) && !Registry::WorkflowDivergence::never_copied($_)
    } slugs_in('registry')->@* ];
}

subtest 'a tenant made by signup holds exactly the workflows its entitlements grant, and each runs' => sub {
    my ( undef, undef, $tenant ) = sign_up('granted_set');
    ok $tenant, 'signup made the tenant';
    my $granted = granted_to($tenant);
    cmp_ok scalar @$granted, '>', 0, 'Solo grants it run rights';
    is_deeply slugs_in('granted_set'), $granted, 'its workflows are exactly those';

    my $tdao = $dao->connect_schema('granted_set');
    for my $slug (@$granted) {
        ok Registry::DAO::Entitlement->tenant_may_run( $db, 'granted_set', $slug ), "$slug passes the run gate";
        ok $tdao->find( Workflow => { slug => $slug } )->new_run( $tdao->db ), "$slug starts a run";
    }

    my $tdb  = $tdao->db;
    my $ids = sub ($sql) { [ sort map { $_->[0] } $tdb->query($sql)->arrays->each ] };
    my $used = $ids->('SELECT DISTINCT outcome_definition_id FROM workflow_steps WHERE outcome_definition_id IS NOT NULL');
    cmp_ok scalar @$used, '>', 0, 'its workflows use outcome definitions';
    is_deeply $ids->('SELECT id FROM outcome_definitions'), $used,
      'it holds exactly the outcome definitions its workflows use';
};

subtest 'no fresh tenant receives tenant-signup or registry-storefront, and provisioning names neither' => sub {
    my ( undef, undef, $tenant ) = sign_up('no_platform_own');
    my %held = map { $_ => 1 } slugs_in('no_platform_own')->@*;
    ok !$held{$_}, "the tenant holds no $_" for qw( tenant-signup registry-storefront );
    my $source = Mojo::File->new('lib/Registry/DAO/Tenant.pm')->slurp;
    ok index( $source, $_ ) < 0, "Tenant.pm does not name $_" for qw( tenant-signup registry-storefront );
};

# --- Negative scenarios ---

subtest 'workflow not granted by entitlement not copied' => sub {
    Workflow->from_yaml( $dao, "name: Ungranted\nslug: ungranted-flow\ndescription: fixture\nroles: [admin]\n"
        . "steps:\n  - slug: first\n    description: x\n  - slug: second\n    description: y\n" );
    my ( undef, undef, $tenant ) = sign_up('ungranted_probe');
    ok !Registry::DAO::Entitlement->may_run( $db, $tenant->id, 'ungranted-flow' ), 'Solo grants no right to it';
    ok !( grep { $_ eq 'ungranted-flow' } slugs_in('ungranted_probe')->@* ), 'and the tenant holds no copy';
};

subtest 'hand inserted tenant-signup copy still refused' => sub {
    my ( undef, undef, $tenant ) = sign_up('hand_copy');
    my $tdao = $dao->connect_schema('hand_copy');
    Workflow->from_yaml( $tdao, Mojo::Home->new->child(qw( workflows tenant-signup.yml ))->slurp );
    ok $tdao->find( Workflow => { slug => 'tenant-signup' } ), 'the tenant holds a hand-made copy';
    ok !Registry::DAO::Entitlement->tenant_may_run( $db, 'hand_copy', 'tenant-signup' ),
      'the run gate refuses it: no entitlement grants it';
};

sub leaves_nothing ($slug) {
    ok !Registry::DAO::Tenant->find( $db, { slug => $slug } ), 'no tenant row';
    ok !$db->query( 'SELECT 1 FROM pg_namespace WHERE nspname = ?', $slug )->rows, 'no schema';
    is $db->query( q{SELECT count(*) FROM registry.entitlements e
                       WHERE NOT EXISTS (SELECT 1 FROM registry.tenants t WHERE t.id = e.holder_tenant_id)}
    )->array->[0], 0, 'no entitlement without its tenant';
}

subtest 'failed provisioning leaves no half tenant' => sub {
    # A copy that fails after the tenant row, schema and entitlement are
    # written: the clone carries this check, which refuses program-creation.
    $db->query(q{ALTER TABLE registry.workflows ADD CONSTRAINT refuse_one_copy
                 CHECK (slug <> 'program-creation') NOT VALID});
    defer { $db->query('ALTER TABLE registry.workflows DROP CONSTRAINT refuse_one_copy') }
    my $died = !eval { sign_up('half_made'); 1 };
    ok $died, 'the failed copy fails signup';
    like $@, qr/refuse_one_copy/, 'on the injected copy failure';
    leaves_nothing('half_made');
};

# Last: it leaves the platform with nothing on offer.
subtest 'signup with no resolvable offer creates no tenant' => sub {
    # The database refuses this state (platform-offer-to-tenants-guard); lifted
    # here so signup's own refusal is proven, as signup-lists-platform-offers.t does.
    $db->query('ALTER TABLE registry.offer_versions DISABLE TRIGGER offer_versions_keep_platform_offer');
    $db->query( q{UPDATE registry.offer_versions SET superseded_at = now()
                   WHERE published_at IS NOT NULL AND superseded_at IS NULL
                     AND NOT conditions @> '[{"kind": "holder_is_offerer"}]'} );
    my ( $run, $review ) = sign_up('no_offer');
    like "@{ $review->{errors} // [] }", qr/signup is unavailable/i, 'signup is refused';
    is $run->next_step($db)->slug, 'review', 'and stays on review';
    leaves_nothing('no_offer');
};

done_testing;
