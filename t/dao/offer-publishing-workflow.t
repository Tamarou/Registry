#!/usr/bin/env perl
# ABOUTME: The offer-publishing workflow, driven through the real WorkflowProcessor and step classes.
# ABOUTME: A tenant admin publishes an immutable, one-time-priced offer version for one of its own resources.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use POSIX ();
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( import_all_workflows join_tenant publish_offer platform_solo_offer_version_id );
use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::OfferVersion;
use Registry::DAO::Resource;
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
# submits each step's fields in order -- every step, even after one stays
# with an error, so a later step cannot publish what an earlier one refused.
# Returns the run and each step's result by slug.
sub walk ( $workflow_dao, $user, %by_step ) {
    my $workflow  = $workflow_dao->find( Workflow => { slug => 'offer-publishing' } );
    my $processor = Registry::WorkflowProcessor->new( dao => $workflow_dao );
    my $run       = $processor->new_run( $workflow, { user => { id => $user->id, name => $user->name } } );
    my %result;
    for my $slug ( ( exists $by_step{resource} ? 'resource' : () ), qw( offer-basics offer-price one-time-payment refund-policy change-policy use-policy expiry-policy publish )) {
        my $step = $workflow->get_step( $workflow_dao->db, { slug => $slug } );
        $result{$slug} = $run->process( $workflow_dao->db, $step, $by_step{$slug} // {} );
    }
    return ( $run, \%result );
}

# Valid answers for every step, with the given steps' fields overridden.
sub terms (%override) {
    my %terms = (
        'offer-basics'     => { resource_id => $seats->id, offer_name => 'Couples wheel night' },
        'offer-price'      => { price_cents => 2500, currency => 'USD', units_per_acceptance => 2, per_booking_cap => 3 },
        'one-time-payment' => { one_time => 'offered' },
        'refund-policy'    => { refund => 'none' },
        'change-policy'    => { change => 'none' },
        'use-policy'       => { use => 'none' },
        'expiry-policy'    => { expiry => 'never' },
        'publish'          => { action => 'publish' },
    );
    for my $slug ( keys %override ) {
        $terms{$slug} = { ( $terms{$slug} // {} )->%*, $override{$slug}->%* };
    }
    return %terms;
}

sub published_count ( $db = $tdb ) {
    return $db->query('SELECT count(*) FROM offer_versions WHERE published_at IS NOT NULL')->array->[0];
}

# Submits $fields to the $slug step of $run, as answering a step again does.
sub answer ( $run, $slug, $fields ) {
    my $step = $tenant_dao->find( Workflow => { slug => 'offer-publishing' } )->get_step( $tdb, { slug => $slug } );
    return $run->process( $tdb, $step, $fields );
}

sub errors_of ($result) { join ' ', ( $result->{errors} // [] )->@* }

my $only_admin = qr/Only an administrator of this tenant can publish an offer/;

subtest 'admin publishes a one time priced offer version' => sub {
    walk( $tenant_dao, $admin, terms() );

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
    is_deeply $v->policies,
        { refund => { kind => 'none' }, change => { kind => 'none' }, use => { kind => 'none' }, expiry => { kind => 'never' } },
        'with explicit none refund, change and use policies and a never expiry';
    is $tdb->query( 'SELECT o.name FROM offers o WHERE o.id = ?', $v->offer_id )->array->[0],
        'Couples wheel night', 'under the offer name given';

    my $ok = eval { $tdb->query( 'UPDATE offer_versions SET price_cents = 1 WHERE id = ?', $v->id ); 1 };
    ok !$ok, 'a direct UPDATE of the published version is refused by the database';
    like $@, qr/immutable once published/, 'as immutable';
};

subtest 'published offer version delete refused' => sub {
    my ($v) = Registry::DAO::OfferVersion->find( $tdb, { published_at => { '!=' => undef } } );
    my $ok = eval { $tdb->query( 'DELETE FROM offer_versions WHERE id = ?', $v->id ); 1 };
    ok !$ok, 'a direct DELETE of a published version is refused by the database';
    like $@, qr/cannot be deleted/, 'as append-only';
};

# Another tenant with a resource of its own, for the cross-schema cases.
Test::Registry::Fixtures::create_tenant( $dao, { name => 'Glass Studio', slug => 'glass_studio' } );
my $glass_db = Registry::DAO->new( url => $test_db->uri, schema => 'glass_studio' )->db;
my $kilns = Test::Registry::Fixtures::create_resource( $glass_db,
    { name => 'Kiln slots', kind => 'finite', capacity => 4 } );

subtest 'foreign or missing resource stays with an error' => sub {
    my $workflow = $tenant_dao->find( Workflow => { slug => 'offer-publishing' } );
    my ( $run ) = walk( $tenant_dao, $admin );
    my $listed = $workflow->get_step( $tdb, { slug => 'offer-basics' } )->prepare_template_data( $tdb, $run );
    is_deeply [ map { $_->id } $listed->{resources}->@* ], [ $seats->id ],
        'offer-basics lists only the resources in the run\'s own schema';

    my $before = published_count();
    for my $case (
        [ 'another tenant\'s resource' => $kilns->id ],
        [ 'a resource that does not exist' => '00000000-0000-0000-0000-00000000abcd' ],
        [ 'an id that is not a uuid' => 'abc' ],
    ) {
        my ( $label, $id ) = @$case;
        my ( $r, $result ) = walk( $tenant_dao, $admin, terms( 'offer-basics' => { resource_id => $id } ) );
        ok $result->{'offer-basics'}{errors}, "$label stays with an error";
        ok !$r->data->{offer_basics}, 'and the run holds no offer';
    }
    is published_count(), $before, 'and nothing is published';
};

subtest 'invalid offer terms stay with an error' => sub {
    my $unbounded = Test::Registry::Fixtures::create_resource( $tdb, { name => 'Studio wifi', kind => 'unbounded' } );
    my $before    = published_count();
    for my $case (
        [ 'a missing price',                 'offer-price'  => { price_cents => undef } ],
        [ 'a negative price',                'offer-price'  => { price_cents => -1 } ],
        [ 'a non-integer price',             'offer-price'  => { price_cents => '25.00' } ],
        [ 'a price that is not a number',    'offer-price'  => { price_cents => 'abc' } ],
        [ 'zero units',                      'offer-price'  => { units_per_acceptance => 0 } ],
        [ 'a cap below one',                 'offer-price'  => { per_booking_cap => 0 } ],
        [ 'units above the capacity',        'offer-price'  => { units_per_acceptance => 11 } ],
        [ 'a malformed currency',            'offer-price'  => { currency => 'US' } ],
        [ 'a currency that is not letters',  'offer-price'  => { currency => 'U$D' } ],
        [ 'an empty offer name',             'offer-basics' => { offer_name => '' } ],
        [ 'a whitespace-only offer name',    'offer-basics' => { offer_name => "  \t " } ],
    ) {
        my ( $label, $slug, $fields ) = @$case;
        my ( undef, $result ) = walk( $tenant_dao, $admin, terms( $slug => $fields ) );
        ok $result->{$slug}{errors}, "$label stays with an error";
        ok $result->{publish}{errors}, 'and publish refuses the run';
    }
    is published_count(), $before, 'nothing is published';

    my ( undef, $result ) = walk( $tenant_dao, $admin, terms(
        'offer-basics' => { resource_id => $unbounded->id },
        'offer-price'  => { units_per_acceptance => 500 },
    ) );
    ok !$result->{'offer-price'}{errors}, 'an unbounded resource has no capacity to exceed';
    is published_count(), $before + 1, 'and publishes';
};

my $staff = Test::Registry::Fixtures::create_user( $dao,
    { username => 'clay_staff', name => 'Clay Staff', email => 'staff@clay.test', user_type => 'staff' } );
join_tenant( $dao, $staff, 'staff', 'clay_studio' );

subtest 'staff run publishes nothing' => sub {
    my $before = published_count();
    my ( undef, $result ) = walk( $tenant_dao, $staff, terms() );
    like errors_of( $result->{publish} ), $only_admin, 'publish refuses a staff run as not an administrator';
    is published_count(), $before, 'and publishes nothing';

    # Staff hold workflow-creation, so they can compose the allowlisted publish
    # step into a workflow of their own and hand it whatever run data they like.
    my $own = Registry::DAO::Workflow->create( $tdb,
        { slug => 'staff-own-publish', name => 'Staff own publish', description => 'composed by staff' } );
    $own->add_step( $tdb, { slug => 'publish', description => 'publish',
        class => 'Registry::DAO::WorkflowSteps::PublishOfferVersion' } );
    my $run = $own->new_run( $tdb, { data => {
        user             => { id => $staff->id },
        offer_basics     => { resource_id => $seats->id, offer_name => 'Staff special' },
        offer_price      => { price_cents => 1, currency => 'usd', units_per_acceptance => 1, per_booking_cap => 1 },
        one_time_payment => { one_time => 'offered' },
        refund_policy    => { kind => 'none' },
        change_policy    => { kind => 'none' },
        use_policy       => { use => 'none' },
    } } );
    my $composed = $run->process( $tdb, $own->first_step($tdb), { action => 'publish' } );
    like errors_of($composed), $only_admin, 'a staff-composed workflow\'s publish step refuses them too';
    is published_count(), $before, 'and publishes nothing';
};

subtest 'forged admin user cannot publish' => sub {
    my $before = published_count();
    my ( $run, $result ) = walk( $tenant_dao, $staff, terms( publish => {
        user    => { id => $admin->id, role => 'admin', user_type => 'admin' },
        user_id => $admin->id,
    } ) );
    like errors_of( $result->{publish} ), $only_admin, 'form data claiming an admin does not get a staff run past publish';
    is published_count(), $before, 'and publishes nothing';
};

subtest 'publish refuses an offer with no payment plan' => sub {
    my $before = published_count();
    my ( undef, $result ) = walk( $tenant_dao, $admin, terms( 'one-time-payment' => { one_time => 'declined' } ) );
    ok !$result->{'one-time-payment'}{errors}, 'declining the one-time plan is a valid answer';
    like errors_of( $result->{publish} ), qr/Offer at least one payment plan/, 'but publish refuses an offer no one can pay for';
    is published_count(), $before, 'and publishes nothing';
};

subtest 'publish refuses another tenant\'s admin and a parent' => sub {
    my $glass_admin = Test::Registry::Fixtures::create_user( $dao,
        { username => 'glass_admin', name => 'Glass Admin', email => 'admin@glass.test', user_type => 'admin' } );
    join_tenant( $dao, $glass_admin, 'admin', 'glass_studio' );
    my $parent = Test::Registry::Fixtures::create_user( $dao,
        { username => 'clay_parent', name => 'Clay Parent', email => 'parent@clay.test', user_type => 'parent' } );
    join_tenant( $dao, $parent, 'parent', 'clay_studio' );

    my $before = published_count();
    for my $case ( [ 'another tenant\'s admin' => $glass_admin ], [ 'a parent of this tenant' => $parent ] ) {
        my ( $label, $user ) = @$case;
        my ( undef, $result ) = walk( $tenant_dao, $user, terms() );
        like errors_of( $result->{publish} ), $only_admin, "publish refuses $label as not an administrator";
    }
    is published_count(), $before, 'and publishes nothing';
};

subtest 'publish rechecks units against the chosen resource capacity' => sub {
    my $pair   = Test::Registry::Fixtures::create_resource( $tdb, { name => 'Pair wheel', kind => 'finite', capacity => 1 } );
    my $before = published_count();
    # Two units of Wheel seats pass the price step; then offer-basics is
    # answered again with a resource that holds only one.
    my ($run) = walk( $tenant_dao, $admin, terms( publish => { action => 'review' } ) );
    ok !answer( $run, 'offer-basics', { resource_id => $pair->id, offer_name => 'Couples wheel night' } )->{errors},
        'offer-basics can be answered again after the price step';
    like errors_of( answer( $run, 'publish', { action => 'publish' } ) ),
        qr/Units per acceptance cannot exceed Pair wheel's capacity of 1/, 'publish refuses units above the new capacity';
    is published_count(), $before, 'and publishes nothing';
};

subtest 'a class offer is held to its smallest occurrence capacity' => sub {
    my $class   = $tdb->insert( 'projects', { name => 'Wheel class', slug => 'wheel-class' }, { returning => 'id' } )->hash->{id};
    my $teacher = $tdb->insert( 'users', { username => 'wheel-teacher' }, { returning => 'id' } )->hash->{id};
    my $room    = $tdb->insert( 'locations', { name => 'Wheel room', slug => 'wheel-room' }, { returning => 'id' } )->hash->{id};
    my $occurrence = sub ( $time, $capacity ) {
        my $event = $tdb->insert( 'events', {
            project_id => $class, location_id => $room, teacher_id => $teacher,
            time       => $time, duration => 90, capacity => $capacity,
        }, { returning => 'id' } )->hash->{id};
        Registry::DAO::Resource->for_occurrence( $tdb, $event );
    };
    $occurrence->( '2099-03-01T10:00:00Z', 10 );
    $occurrence->( '2099-03-08T10:00:00Z', 3 );
    my %as_class = (
        resource        => { resource_mode => 'class', class_project_id => $class },
        'expiry-policy' => { expiry => 'end_of_occurrence' },
    );

    my $before = published_count();
    my ( undef, $result ) = walk( $tenant_dao, $admin, terms( %as_class, 'offer-price' => { units_per_acceptance => 4 } ) );
    like errors_of( $result->{'offer-price'} ), qr/cannot exceed 3, the smallest capacity among Wheel class's occurrences/,
        'the price step refuses units above the smallest occurrence capacity';
    ok $result->{publish}{errors}, 'and publish refuses the run';
    is published_count(), $before, 'publishing nothing';

    my ($run) = walk( $tenant_dao, $admin, terms( %as_class, 'offer-price' => { units_per_acceptance => 3 }, publish => { action => 'review' } ) );
    $occurrence->( '2099-03-15T10:00:00Z', 2 );
    like errors_of( answer( $run, 'publish', { action => 'publish' } ) ),
        qr/cannot exceed 2, the smallest capacity among Wheel class's occurrences/,
        'publish refuses units above an occurrence added after the price step';
    is published_count(), $before, 'and publishes nothing';
};

subtest 'a failed publish shows a fixed message and logs the detail' => sub {
    # An admin may compose the publish step into a workflow of their own and
    # hand it run data no step checked: here, a resource that does not exist.
    my $own = Registry::DAO::Workflow->create( $tdb,
        { slug => 'admin-own-publish', name => 'Admin own publish', description => 'composed by an admin' } );
    $own->add_step( $tdb, { slug => 'publish', description => 'publish',
        class => 'Registry::DAO::WorkflowSteps::PublishOfferVersion' } );
    my $missing = '00000000-0000-0000-0000-00000000abcd';
    my $run = $own->new_run( $tdb, { data => {
        user             => { id => $admin->id },
        offer_basics     => { resource_id => $missing, offer_name => 'Ghost night' },
        offer_price      => { price_cents => 1, currency => 'usd', units_per_acceptance => 1, per_booking_cap => 1 },
        one_time_payment => { one_time => 'offered' },
        refund_policy    => { kind => 'none' },
        change_policy    => { kind => 'none' },
        use_policy       => { use => 'none' },
        expiry_policy    => { expiry => 'never' },
    } } );

    my $before = published_count();
    my @logged;
    my $result = do {
        local $SIG{__WARN__} = sub { push @logged, @_ };
        $run->process( $tdb, $own->first_step($tdb), { action => 'publish' } );
    };
    is_deeply $result->{errors}, ['The offer could not be published, and nothing was saved. Please try again.'],
        'the screen shows a fixed message';
    unlike errors_of($result), qr/abcd|constraint|violat|DBD|line \d/i, 'with no internal text in it';
    like join( '', @logged ), qr/offer publish failed.*violates foreign key constraint/s, 'the detail is logged';
    is published_count(), $before, 'and nothing is published';
    is $tdb->query( 'SELECT count(*) FROM offers WHERE name = ?', 'Ghost night' )->array->[0], 0,
        'not even an unpublished offer';
};

subtest 'double publish leaves one version' => sub {
    my $before = published_count();
    my ( $run ) = walk( $tenant_dao, $admin, terms() );
    is published_count(), $before + 1, 'the run publishes one version';

    my $publish = $tenant_dao->find( Workflow => { slug => 'offer-publishing' } )
        ->get_step( $tdb, { slug => 'publish' } );
    $run->process( $tdb, $publish, { action => 'publish' } );
    is published_count(), $before + 1, 'submitting publish again publishes nothing more';

    # Two connections and a fork, so the second submission really runs while
    # the first holds its transaction open.
    $before = published_count();
    ( $run ) = walk( $tenant_dao, $admin, terms( publish => { action => 'review' } ) );
    my $uri = $test_db->uri;
    pipe( my $child_reads, my $parent_writes ) or die "pipe: $!";
    my $pid = fork() // die "fork: $!";
    unless ($pid) {
        close $parent_writes;
        readline $child_reads;
        my $bdao = Registry::DAO->new( url => $uri, schema => 'clay_studio' );
        my $ok   = eval {
            my $brun = $bdao->find( WorkflowRun => { id => $run->id } );
            $brun->process( $bdao->db, $publish, { action => 'publish' } );
            1;
        };
        print STDERR "child publish failed: $@" unless $ok;
        POSIX::_exit( $ok ? 0 : 1 );
    }
    close $child_reads;
    my $adao = Registry::DAO->new( url => $uri, schema => 'clay_studio' );
    my $adb  = $adao->db;
    my $tx   = $adb->begin;
    $adao->find( WorkflowRun => { id => $run->id } )
        ->process( $adb, $publish, { action => 'publish' } );
    my $holder = $adb->query('SELECT pg_backend_pid()')->array->[0];
    print $parent_writes "go\n";
    $parent_writes->flush;

    # Commit only once the second submission is blocked behind this
    # transaction's lock, as Postgres itself reports it, so it cannot finish
    # first and pass without the lock.
    my ( $blocked, $deadline ) = ( 0, time + 30 );
    $blocked = $tdb->query( 'SELECT count(*) FROM pg_stat_activity WHERE ? = ANY (pg_blocking_pids(pid))', $holder )
        ->array->[0] until $blocked || time > $deadline;
    ok $blocked, 'the second submission waits on the first one\'s lock';
    $tx->commit;
    waitpid $pid, 0;
    is $? >> 8, 0, 'the concurrent submission completes';
    is published_count(), $before + 1, 'two concurrent submissions publish one version';
};

subtest 'skeleton publishes with an explicit none refund policy' => sub {
    my $version = publish_offer( $dao, 'clay_studio', $admin, {
        'offer-basics' => { resource_id => $seats->id, offer_name => 'Glaze night' },
        'offer-price'  => { price_cents => 1500, currency => 'usd', units_per_acceptance => 1, per_booking_cap => 2 },
    } );
    ok $version->is_published, 'the offer publishes';
    is_deeply $version->policies->{refund}, { kind => 'none' }, 'with an explicit none refund policy';
};

subtest 'skeleton refuses to publish without a refund choice' => sub {
    my $before = published_count();
    my $ok = eval {
        publish_offer( $dao, 'clay_studio', $admin, {
            'offer-basics' => { resource_id => $seats->id, offer_name => 'Glaze night again' },
            'offer-price'  => { price_cents => 1500, currency => 'usd', units_per_acceptance => 1, per_booking_cap => 2 },
            refund         => undef,
        } );
        1;
    };
    ok !$ok, 'publishing without a refund choice is refused';
    like $@, qr/refund/i, 'for want of the refund choice';
    is published_count(), $before, 'and publishes nothing';
};

subtest 'publish offer helper drives the workflow' => sub {
    my $version = publish_offer( $dao, 'clay_studio', $admin, {
        'offer-basics' => { resource_id => $seats->id, offer_name => 'Helper night' },
        'offer-price'  => { price_cents => 900, currency => 'usd', units_per_acceptance => 1, per_booking_cap => 1 },
    } );
    is $version->price_cents, 900, 'the helper returns the version it published';
    is_deeply $version->payment_plans($tdb), [ { id => 'one_time', kind => 'one_time', fraction => undef } ],
        'with the one-time plan its default offers';
    is $tdb->query( q{
        SELECT count(*) FROM workflow_runs r JOIN workflows w ON w.id = r.workflow_id
         WHERE w.slug = 'offer-publishing' AND r.data->>'published_offer_version_id' = ?
    }, $version->id )->array->[0], 1, 'through an offer-publishing run';
};

subtest 'platform publishes through the same workflow' => sub {
    my $alex = Test::Registry::Fixtures::create_user( $dao,
        { username => 'alex', name => 'Alex', email => 'alex@registry.test', user_type => 'admin' } );
    join_tenant( $dao, $alex, 'admin' );
    my $rdb      = $dao->db;
    my $coaching = Test::Registry::Fixtures::create_resource( $rdb,
        { name => 'Onboarding call', kind => 'finite', capacity => 1 } );

    my $before = published_count($rdb);
    walk( $dao, $alex, terms(
        'offer-basics' => { resource_id => $coaching->id, offer_name => 'Onboarding call' },
        'offer-price'  => { units_per_acceptance => 1, per_booking_cap => 1 },
    ) );
    is published_count($rdb), $before + 1, 'registry\'s admin publishes an offer version';
    my ($v) = Registry::DAO::OfferVersion->find( $rdb, { resource_id => $coaching->id } );
    ok $v && $v->is_published, 'owned by the platform tenant, in the registry schema';

    my $classes = sub ($db) {
        $db->query( q{
            SELECT s.slug, s.class FROM workflow_steps s JOIN workflows w ON w.id = s.workflow_id
             WHERE w.slug = 'offer-publishing' ORDER BY s.slug
        } )->arrays->to_array;
    };
    is_deeply $classes->($rdb), $classes->($tdb), 'through the same steps and step classes as a tenant';

    is platform_solo_offer_version_id($dao), '00000000-0000-0000-0003-000000000001',
        'the platform\'s current Solo version is the bootstrap\'s';
};

done_testing;
