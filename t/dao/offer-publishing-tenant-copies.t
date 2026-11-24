#!/usr/bin/env perl
# ABOUTME: Pins how tenant copies of offer-publishing relate to step-4 changes: a new tenant gets the platform's current copy,
# ABOUTME: and the offer-publishing-* migrations change only registry, so a tenant keeps running its own copy.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

# Why tenant copies are not migrated: offer-publishing and every step-4
# migration that reshapes it ship in one PR and one deploy (ruling 14a), so
# no released tenant holds a copy older than the platform's. A later platform
# change reaches tenants through step 6 (copy on accepting the offer, under
# the divergence rulings); a migration must never overwrite a tenant's copy.

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Mojo::File qw(path);
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( import_all_workflows join_tenant publish_offer );
use Registry::DAO;
use Registry::DAO::Tenant;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
import_all_workflows($dao);

my $admin = Test::Registry::Fixtures::create_user( $dao,
    { username => 'kiln_admin', name => 'Kiln Admin', email => 'admin@kiln.test', user_type => 'admin' } );
Registry::DAO::Tenant->provision( $dao->db, { name => 'Kiln', slug => 'kiln', users => [$admin] } );
join_tenant( $dao, $admin, 'admin', 'kiln' );

# Step slugs of $schema's offer-publishing, in walk order.
sub steps ($schema) {
    my $tenant_dao = $schema eq 'registry' ? $dao : $dao->connect_schema($schema);
    my $workflow   = $tenant_dao->find( Workflow => { slug => 'offer-publishing' } ) or return [];
    my @slugs;
    for ( my $step = $workflow->first_step( $tenant_dao->db ) ; $step ; $step = $step->next_step( $tenant_dao->db ) ) {
        push @slugs, $step->slug;
    }
    return \@slugs;
}

sub tenant_rows () {
    $dao->db->query(q{
        SELECT w.id AS wf_id, s.*
          FROM kiln.workflows w JOIN kiln.workflow_steps s ON s.workflow_id = w.id
         WHERE w.slug = 'offer-publishing' ORDER BY s.id
    })->hashes->to_array;
}

subtest 'a new tenant gets the platform current copy' => sub {
    ok scalar steps('kiln')->@*, 'the provisioned tenant holds offer-publishing';
    is_deeply steps('kiln'), steps('registry'), 'with the platform steps, in order';
};

subtest 'step-4 migrations change only registry' => sub {
    # Make the tenant's copy older than the platform's: drop use-policy, relinking publish.
    my ($wf) = $dao->db->query(q{SELECT id FROM kiln.workflows WHERE slug = 'offer-publishing'})->array->@*;
    $dao->db->query( q{
        UPDATE kiln.workflow_steps p SET depends_on = u.depends_on
          FROM kiln.workflow_steps u
         WHERE p.depends_on = u.id AND u.slug = 'use-policy' AND u.workflow_id = ?
    }, $wf );
    $dao->db->query( q{DELETE FROM kiln.workflow_steps WHERE slug = 'use-policy' AND workflow_id = ?}, $wf );
    my $before = tenant_rows();

    # Deploy as production does: every offer-publishing migration, then the registry import.
    my @migrations = path('sql/deploy')->list->grep(qr{/offer-publishing-[^/]+\.sql$})->each;
    ok @migrations, 'found the offer-publishing migrations';
    for my $file (@migrations) {
        my $sql = $file->slurp;
        $sql =~ s/^\s*(?:BEGIN|COMMIT);\s*$//mg;
        $dao->db->query($sql);
    }
    $dao->db->query('SET search_path = registry, public');
    import_all_workflows($dao);

    ok( ( grep { $_ eq 'use-policy' } steps('registry')->@* ), 'registry is rebuilt with the new step' );
    is_deeply tenant_rows(), $before, "the tenant's copy is untouched";

    my $seats = Test::Registry::Fixtures::create_resource( $dao->connect_schema('kiln')->db,
        { name => 'Seats', kind => 'finite', capacity => 4 } );
    eval {
        publish_offer( $dao, 'kiln', $admin, {
            resource_id => $seats->id, offer_name => 'Night', price_cents => 2500,
            currency => 'USD', units_per_acceptance => 1, per_booking_cap => 1,
        } );
    };
    like $@, qr/Choose a use policy before publishing/, "the tenant runs its own copy, not registry's";
};

done_testing;
