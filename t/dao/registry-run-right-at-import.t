#!/usr/bin/env perl
# ABOUTME: registry gains the run right to each workflow inserted into registry.workflows, through the import trigger.
# ABOUTME: Re-importing a workflow whose right registry ended neither aborts the import nor revives the right.
use 5.42.0;
use warnings;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Entitlement;
use Registry::DAO::Tenant;
use Registry::DAO::Workflow;

my $test_db  = Test::Registry::DB->new;
my $dao      = $test_db->db;
my $db       = $dao->db;
my $registry = Registry::DAO::Tenant->find( $db, { slug => 'registry' } );

sub import_flow ($slug) {
    Registry::DAO::Workflow->create( $db, { name => $slug, slug => $slug, description => 'fixture', roles => ['admin'] } );
}

# registry's run-right entitlement to $slug, active or ended.
sub registry_right ($slug) {
    my ($e) = grep { $_->holder_tenant_id eq $registry->id }
      map { Registry::DAO::Entitlement->find( $db, { offer_version_id => $_ } ) }
      $db->query( q{SELECT v.id FROM registry.offer_versions v JOIN registry.resources r ON r.id = v.resource_id
                     WHERE r.name = ?}, "run:$slug" )->arrays->flatten->each;
    return $e;
}

subtest 'an imported workflow gives registry its run right' => sub {
    import_flow('imported-flow');
    ok Registry::DAO::Entitlement->may_run( $db, $registry->id, 'imported-flow' ), 'registry may run it';
};

subtest 're-importing a workflow whose run right ended skips cleanly' => sub {
    import_flow('ended-flow');
    registry_right('ended-flow')->end( $db, 'expired', 'run right ended by hand' );
    ok !Registry::DAO::Entitlement->may_run( $db, $registry->id, 'ended-flow' ), 'the right has ended';

    $db->delete( 'workflows', { slug => 'ended-flow' } );
    ok eval { import_flow('ended-flow'); 1 }, 'the re-import is not aborted' or diag $@;
    ok $dao->find( 'Registry::DAO::Workflow', { slug => 'ended-flow' } ), 'the workflow is imported';
    ok !Registry::DAO::Entitlement->may_run( $db, $registry->id, 'ended-flow' ), 'the ended right is not revived';
};

done_testing;
