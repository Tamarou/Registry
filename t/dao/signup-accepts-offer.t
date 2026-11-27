#!/usr/bin/env perl
# ABOUTME: Signup's tenant accepts its chosen platform offer: one stamped entitlement in registry, written with the tenant.
# ABOUTME: Also the accept primitive's refusals: stale or foreign versions, unoffered or one-time plans, a second schedule.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Fork qw( forget_inherited_handles reap );
use POSIX ();

use Test::Registry::DB;
use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::DAO::Tenant;
use Registry::DAO::Entitlement;
use Registry::DAO::Offer;
use Registry::DAO::OfferVersion;
use Registry::DAO::User;
use Registry::Utility::WorkflowProcessor;
use Registry::PriceOps::RevenueShare qw( revenue_share_fraction_for_tenant );
use Test::Registry::Offers qw( offer_terms );

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

$dao->import_workflows( ['workflows/tenant-signup.yml'] );
my ($workflow) = Registry::DAO::Workflow->find( $db, { slug => 'tenant-signup' } );
my ($review)   = $workflow->get_step( $db, { slug => 'review' } );

# Solo v3's fixed id (solo-grants-session-workflows) and the bootstrap's payment processing.
my $SOLO_V3            = '2f570c64-dad4-c0aa-5848-3219eb752c76';    # solo-grants-session-workflows'
my $PAYMENT_PROCESSING = '00000000-0000-0000-0001-000000000001';
my $SELF_OFFER = $db->query( q{SELECT id FROM registry.offer_versions
                                WHERE conditions @> '[{"kind": "holder_is_offerer"}]' LIMIT 1} )->array->[0];

sub signup_data ($slug) {
    return {
        name            => "Studio $slug",
        subdomain       => $slug,
        admin_name      => 'Accept Admin',
        admin_email     => "${slug}_admin\@test.example",
        admin_username  => "${slug}_admin",
        admin_user_type => 'admin',
        profile         => { name => "Studio $slug", slug => $slug },
    };
}

# A signup run that has reached the review page, whose button provisions.
sub signup_run ($slug) {
    return Registry::DAO::WorkflowRun->create( $db, { workflow_id => $workflow->id, data => signup_data($slug) } );
}

sub tenant_id ($slug) {
    my $row = $db->query( 'SELECT id FROM registry.tenants WHERE slug = ?', $slug )->hash;
    return $row && $row->{id};
}

sub schema_exists ($slug) {
    return $db->query( 'SELECT count(*) FROM pg_namespace WHERE nspname = ?', $slug )->array->[0];
}

sub held ($slug) {
    my $id = tenant_id($slug) or return [];
    return [ Registry::DAO::Entitlement->find( $db, { holder_tenant_id => $id } ) ];
}

sub entitlement_count { $db->query('SELECT count(*) FROM registry.entitlements')->array->[0] }

sub user_exists ($slug) { !!Registry::DAO::User->find( $db, { username => "${slug}_admin" } ) }

# A tenant row with no platform entitlement: a holder to accept for.
sub bare_tenant ($slug) { Registry::DAO::Tenant->create( $db, { name => "Bare $slug", slug => $slug } ) }

sub solo ( $holder_id, $plan = 'revenue_share', $version = $SOLO_V3 ) {
    return { offer_version_id => $version, payment_plan_id => $plan, holder_tenant_id => $holder_id };
}

# Runs $code in a forked child on its own connection, once this process's
# connection $adb holds what it waits for; commits $tx once the child waits on
# $adb's locks, as pg_blocking_pids reports it. Returns whether it waited and
# what the child printed.
sub while_blocked ( $adb, $tx, $code ) {
    my $uri = $test_db->uri;
    pipe( my $parent_reads, my $child_writes ) or die "pipe: $!";
    my $pid = fork() // die "fork: $!";
    unless ($pid) {
        forget_inherited_handles();
        close $parent_reads;
        my $out = eval { $code->( Registry::DAO->new( url => $uri )->db ) } // "child died: $@";
        print $child_writes $out;
        close $child_writes;
        POSIX::_exit(0);
    }
    close $child_writes;
    my $holder = $adb->query('SELECT pg_backend_pid()')->array->[0];
    my ( $blocked, $deadline ) = ( 0, time + 30 );
    until ( $blocked || waitpid( $pid, POSIX::WNOHANG() ) || time > $deadline ) {
        select undef, undef, undef, 0.05;
        $blocked = $db->query( 'SELECT count(*) FROM pg_stat_activity WHERE ? = ANY (pg_blocking_pids(pid))', $holder )
            ->array->[0];
    }
    $tx->commit;
    reap($pid);
    return ( $blocked, do { local $/; readline $parent_reads } );
}

sub refusal_of ($code) {
    my $ok = eval { $code->(); 1 };
    return $ok ? undef : $@;
}

subtest 'signup with solo grants stamped entitlement' => sub {
    my $slug      = 'solo_walk_studio';
    my $processor = Registry::WorkflowProcessor->new( dao => $db );
    my $run       = $processor->new_run( $workflow, signup_data($slug) );
    for my $slug_ (qw( profile users )) {
        $processor->process_workflow_run_step( $run, $workflow->get_step( $db, { slug => $slug_ } ), {} );
    }
    $processor->process_workflow_run_step( $run, $review, { offer_version => $SOLO_V3 } );
    $processor->process_workflow_run_step( $run, $workflow->get_step( $db, { slug => 'complete' } ), {} );
    ok $run->completed($db), 'the signup run completed';

    my $held = held($slug);
    is scalar @$held, 1, 'the new tenant holds one entitlement in registry';
    my $e = $held->[0] or return;
    is $e->offer_version_id, $SOLO_V3,         'stamped with Solo v3';
    is $e->payment_plan_id,  'revenue_share',  'under its percentage-of-sales plan';
    ok $e->is_in_effect($db), 'in effect now';
    is revenue_share_fraction_for_tenant( $db, $slug ), '0.025', 'its revenue share resolves to 2.5%';
};

subtest 'provisioning and acceptance commit together' => sub {
    my $slug = 'together_studio';
    signup_run($slug)->process( $db, $review, { offer_version => $SOLO_V3 } );
    my ($e) = held($slug)->@* or return fail 'no entitlement';
    my $xid = sub ( $table, $id ) { $db->query( "SELECT xmin::text FROM registry.$table WHERE id = ?", $id )->array->[0] };
    my $admin = Registry::DAO::User->find( $db, { username => "${slug}_admin" } );
    is $xid->( entitlements => $e->id ), $xid->( tenants => tenant_id($slug) ),
        'the entitlement was written in the transaction that wrote the tenant';
    is $xid->( users => $admin->id ), $xid->( tenants => tenant_id($slug) ),
        'and so was its admin user';
};

subtest 're-run provisioning leaves one tenant and one entitlement' => sub {
    my $slug = 'rerun_studio';
    my $run  = signup_run($slug);
    $run->process( $db, $review, { offer_version => $SOLO_V3 } );
    my $again = eval { $review->_provision_tenant( $db, $run ) };
    is $@, '', 'provisioning the run again does not die';
    is $again && $again->{tenant}, tenant_id($slug), 'and answers with the same tenant';
    is $db->query( 'SELECT count(*) FROM registry.tenants WHERE slug LIKE ?', "$slug%" )->array->[0], 1, 'one tenant';
    is scalar held($slug)->@*, 1, 'one entitlement';
};

subtest 'self offer refused at provisioning' => sub {
    ok $SELF_OFFER, 'the platform has an offer to itself';
    my $slug   = 'self_offer_studio';
    my $run    = signup_run($slug);
    $run->update_data( $db, { selected_offer_version => $SELF_OFFER } );
    my $before = entitlement_count();
    my $result = eval { $review->_provision_tenant( $db, $run ) };
    is $@, '', 'refused, not a server error';
    ok $result && $result->{errors}, 'provisioning refuses it';
    ok !tenant_id($slug),   'no tenant';
    ok !user_exists($slug), 'no user';
    is entitlement_count(), $before, 'no entitlement';
};

subtest 'foreign offer version refused at signup' => sub {
    my $host = bare_tenant('foreign_host');
    $db->query( 'SELECT clone_schema(?)', 'foreign_host' );
    $db->query('SET search_path = registry, public');
    my $tdb   = Registry::DAO->new( url => $test_db->uri, schema => 'foreign_host' )->db;
    my $offer = Registry::DAO::Offer->create( $tdb, { name => 'Their Plan' } );
    my $resource = $tdb->query( q{INSERT INTO resources (name, kind) VALUES ('payment processing', 'unbounded') RETURNING id} )
        ->array->[0];
    my $theirs = $offer->draft( $tdb, offer_terms( $resource, price_cents => 0,
        payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => 0.001 } ] ) )->publish($tdb);

    my $before = entitlement_count();
    my $slug   = 'foreign_studio';
    my $result = signup_run($slug)->process( $db, $review, { offer_version => $theirs->id } );
    ok $result->{errors}, 'signup refuses the posted foreign version';

    my $run = signup_run("${slug}_2");
    $run->update_data( $db, { selected_offer_version => $theirs->id } );
    $result = eval { $review->_provision_tenant( $db, $run ) };
    is $@, '', 'provisioning refuses, not a server error';
    ok $result && $result->{errors}, 'provisioning refuses the carried foreign version';
    ok !tenant_id($_), "no tenant $_" for $slug, "${slug}_2";
    is entitlement_count(), $before, 'no entitlement';
};

subtest 'client holder version or plan fields ignored' => sub {
    my $slug   = 'client_fields_studio';
    my $victim = bare_tenant('victim_studio');
    my %forged = (
        holder_tenant_id     => $victim->id,
        offer_version_id     => $SELF_OFFER,
        payment_plan_id      => 'operator',
        platform_entitlement => { offer_version_id => $SELF_OFFER, payment_plan_id => 'operator' },
        rate                 => '0',
        revenue_share_percent => 0,
        plan_name            => 'Free',
    );
    my $processor = Registry::WorkflowProcessor->new( dao => $db );
    my $run       = $processor->new_run( $workflow, { %{ signup_data($slug) }, %forged } );
    $processor->process_workflow_run_step( $run, $workflow->get_step( $db, { slug => $_ } ), \%forged )
        for qw( profile users );
    $processor->process_workflow_run_step( $run, $review, { %forged, offer_version => $SOLO_V3 } );

    my ($e) = held($slug)->@* or return fail 'no entitlement';
    is $e->holder_tenant_id, tenant_id($slug), 'held by the new tenant';
    is $e->offer_version_id, $SOLO_V3,         'stamped with the version the review step validated';
    is $e->payment_plan_id,  'revenue_share',  'under that version\'s plan';
    is scalar held('victim_studio')->@*, 0, 'the named holder got nothing';
    is revenue_share_fraction_for_tenant( $db, $slug ), '0.025', 'at 2.5%, not a submitted rate';
};

subtest 'payment plan not offered refused' => sub {
    my $t      = bare_tenant('unoffered_plan');
    my $before = entitlement_count();
    my $err    = refusal_of( sub { Registry::DAO::Entitlement->accept( $db, solo( $t->id, 'monthly' ) ) } );
    isa_ok $err, 'Registry::DAO::Entitlement::Refused';
    like $err && $err->message, qr/does not offer payment plan 'monthly'/, 'naming the plan';
    is entitlement_count(), $before, 'no entitlement';
};

subtest 'one time plan without payment creates nothing' => sub {
    my $offer = Registry::DAO::Offer->create( $db, { name => 'Setup Fee' } );
    my $fee   = $offer->draft( $db, offer_terms($PAYMENT_PROCESSING) )->publish($db);
    my $t      = bare_tenant('one_time_holder');
    my $before = entitlement_count();
    my $err    = refusal_of( sub { Registry::DAO::Entitlement->accept( $db, solo( $t->id, 'pay', $fee->id ) ) } );
    isa_ok $err, 'Registry::DAO::Entitlement::Refused';
    like $err && $err->message, qr/one-time/, 'as a one-time plan';
    is entitlement_count(), $before, 'no entitlement';
};

subtest 'second schedule offer entitlement refused' => sub {
    my $t     = bare_tenant('twice_holder');
    my $first = Registry::DAO::Entitlement->accept( $db, solo( $t->id ) );
    ok $first && $first->is_in_effect($db), 'the first accept grants Solo';
    my $err = refusal_of( sub { Registry::DAO::Entitlement->accept( $db, solo( $t->id ) ) } );
    isa_ok $err, 'Registry::DAO::Entitlement::Refused', 'the second is refused with a message';
    like $err && $err->message, qr/already holds/, 'saying it is already held';
    is scalar held('twice_holder')->@*, 1, 'one entitlement';
};

subtest 'concurrent accepts create one entitlement' => sub {
    my $t   = bare_tenant('race_holder');
    my $adb = Registry::DAO->new( url => $test_db->uri )->db;
    my $tx  = $adb->begin;
    Registry::DAO::Entitlement->accept( $adb, solo( $t->id ) );
    my ( $blocked, $child ) = while_blocked( $adb, $tx, sub ($cdb) {
        my $err = refusal_of( sub { Registry::DAO::Entitlement->accept( $cdb, solo( $t->id ) ) } );
        return ref $err ? ref($err) . ': ' . $err->message : "not refused: " . ( $err // 'granted' );
    } );
    ok $blocked, 'the second accept waited on the first';
    like $child, qr/\ARegistry::DAO::Entitlement::Refused: .*already holds/, 'and was refused with a message';
    is scalar held('race_holder')->@*, 1, 'one entitlement';
};

subtest 'failed provisioning leaves nothing behind' => sub {
    ok $db->query('SELECT count(*) FROM registry.program_types')->array->[0], 'registry has program types to copy';
    # A constraint the clone copies and registry's own rows break: the copy
    # after the accept and the schema clone fails.
    $db->query('ALTER TABLE registry.program_types ADD CONSTRAINT refuse_copy CHECK (false) NOT VALID');
    my $slug   = 'failing_studio';
    my $before = entitlement_count();
    my $ok     = eval { signup_run($slug)->process( $db, $review, { offer_version => $SOLO_V3 } ); 1 };
    $db->query('SET search_path = registry, public');
    $db->query('ALTER TABLE registry.program_types DROP CONSTRAINT refuse_copy');
    ok !$ok, 'provisioning failed';
    ok !tenant_id($slug),     'no tenant row';
    ok !schema_exists($slug), 'no tenant schema';
    ok !user_exists($slug),   'no user';
    is entitlement_count(), $before, 'no entitlement';
};

# Last: it supersedes Solo v3.
subtest 're-versioned solo refused and re-quoted with no tenant' => sub {
    my $slug   = 'reversioned_studio';
    my $run    = signup_run($slug);
    my $before = entitlement_count();
    my $adb    = Registry::DAO->new( url => $test_db->uri )->db;
    my $tx     = $adb->begin;
    my $solo   = Registry::DAO::OfferVersion->find( $adb, { id => $SOLO_V3 } );
    my $next     = Registry::DAO::OfferVersion->draft( $adb, $solo->offer_id, offer_terms( $PAYMENT_PROCESSING,
        price_cents   => 0,
        payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => 0.03 } ],
    ) )->publish($adb);

    my ( $blocked, $child ) = while_blocked( $adb, $tx, sub ($cdb) {
        my $result = Registry::DAO::WorkflowRun->find( $cdb, { id => $run->id } )
            ->process( $cdb, $review, { offer_version => $SOLO_V3 } );
        return join '; ', ( $result->{errors} // ['no errors'] )->@*;
    } );
    ok $blocked, 'the accept waited on the re-versioning';
    like $child, qr/changed/, 'signup refused with a message';
    ok !tenant_id($slug),     'no tenant row';
    ok !schema_exists($slug), 'no tenant schema';
    ok !user_exists($slug),   'no user';
    is entitlement_count(), $before, 'no entitlement';

    $run = Registry::DAO::WorkflowRun->find( $db, { id => $run->id } );
    is $run->data->{selected_offer_version}, $next->id, 'the run now carries Solo\'s current version';
    is $review->get_subscription_config( $db, $run )->{revenue_share_percent}, 3, 'and quotes its terms';

    $run->process( $db, $review, { offer_version => $next->id } );
    is held($slug)->[0] && held($slug)->[0]->offer_version_id, $next->id, 'accepting again grants the current version';
};

$test_db->cleanup_test_database;
done_testing;
