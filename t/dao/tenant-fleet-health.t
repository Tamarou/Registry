#!/usr/bin/env perl
# ABOUTME: One row per tenant with what Alex has to know: billing, Connect, and whether it provisioned.
# ABOUTME: A half-provisioned schema is reported, not raised -- #265's rows are the reason this exists.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Workflow;
use Mojo::Home;
use YAML::XS qw(Load);
use Registry;
use Registry::Command::template;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# Workflows have to exist in registry before a tenant can be provisioned WITH
# them: provision copies per-workflow (and templates per workflow step), so a
# registry schema with none produces a tenant with none -- which the fleet query
# would then correctly report as unhealthy. Importing them is what makes this
# fixture a provisioned tenant rather than an empty one.
for my $file ( Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each ) {
    next if Load( $file->slurp )->{draft};
    Registry::DAO::Workflow->from_yaml( $dao, $file->slurp );
}

# Templates too, through the command production uses (docker-entrypoint.sh runs
# `template import` on every deploy). provision copies them per workflow step,
# so a registry schema without them produces a tenant without them.
{
    local $ENV{DB_URL} = $test_db->uri;
    my $app = Registry->new;
    my $out = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$out;
        Registry::Command::template->new( app => $app )->load('registry');
    }
}

# A healthy tenant, provisioned the way provision() does it.
my $owner = Registry::DAO::User->create( $db, {
    username => 'fleet_owner', name => 'Fleet Owner', user_type => 'admin',
    email => 'owner@fleet.test',
} );
my $healthy = Registry::DAO::Tenant->provision( $db, {
    name => 'Healthy Studio', slug => 'healthy_studio',
    users => [ $owner ],
} );

# And one whose schema was never built: a tenant row with nothing behind it.
# This is the shape #265 is about -- the sweeps isolate these and nothing
# reports them, so a customer is broken and invisible until they complain.
my $broken = Registry::DAO::Tenant->create( $db, {
    name => 'Broken Studio', slug => 'broken_studio',
} );

sub fleet_by_slug () {
    return { map { $_->{slug} => $_ } @{ Registry::DAO::Tenant->fleet($db) } };
}

subtest 'every tenant is listed, with what Alex is asked to know' => sub {
    my $fleet = fleet_by_slug();

    ok $fleet->{healthy_studio}, 'the provisioned tenant is there';
    ok $fleet->{broken_studio},  'and so is the one that never provisioned';

    my $row = $fleet->{healthy_studio};
    is $row->{name}, 'Healthy Studio', 'name';
    ok $row->{created_at}, 'created';
    ok exists $row->{billing_status}, 'billing status';
    ok exists $row->{canonical_domain}, 'canonical domain';
    ok exists $row->{stripe_connect_account_id}, 'Connect account';
    ok exists $row->{stripe_charges_enabled}, 'and whether it can take money';
};

subtest 'provisioning health is reported per tenant' => sub {
    my $fleet = fleet_by_slug();

    my $ok = $fleet->{healthy_studio};
    ok $ok->{schema_present}, 'the schema exists';
    ok $ok->{health}{workflows} > 0, 'workflows were imported';
    ok $ok->{health}{templates} > 0, 'templates were imported';
    ok $ok->{health}{owner_resident},
        'and the owner is resident in the tenant schema, not only in registry';
    ok $ok->{healthy}, 'so the tenant reads as healthy';
};

subtest 'a tenant with no schema is reported, not raised' => sub {
    # The whole point. Asking a missing schema for its workflow count raises,
    # and a screen that dies on the first broken tenant tells Alex nothing about
    # any of the others -- which is the state he is in today with psql.
    my $fleet = fleet_by_slug();
    my $row = $fleet->{broken_studio};

    ok !$row->{schema_present}, 'the missing schema is named as missing';
    ok !$row->{healthy}, 'the tenant does not read as healthy';
    ok $row->{problems} && @{ $row->{problems} },
        'and it says what is wrong rather than merely being falsy';
};

subtest 'a half-provisioned schema does not take the fleet down' => sub {
    # Worse than absent: the schema exists and its tables do not. provision()
    # is transactional now, but #330 and #265 both exist because rows of this
    # shape reached production.
    $db->query('CREATE SCHEMA IF NOT EXISTS half_studio');
    my $half = Registry::DAO::Tenant->create( $db, {
        name => 'Half Studio', slug => 'half_studio',
    } );

    my $fleet = eval { fleet_by_slug() };
    ok $fleet, 'the fleet still answers' or diag "raised: $@";

    my $row = $fleet->{half_studio};
    ok $row->{schema_present}, 'the schema is there';
    ok !$row->{healthy}, 'but the tenant is not healthy';
    ok scalar( grep { /workflows|table|relation/i } @{ $row->{problems} || [] } ),
        'and the problem names what could not be read';

    # The others are still reported, which is the reason to catch rather than die.
    ok $fleet->{healthy_studio}{healthy}, 'the healthy tenant is unaffected';
};

done_testing;
