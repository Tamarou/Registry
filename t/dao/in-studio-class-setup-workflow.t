#!/usr/bin/env perl
# ABOUTME: The in-studio class setup workflow, driven through the real WorkflowProcessor and step classes.
# ABOUTME: A studio admin defines a class (location, seats per occurrence) and publishes its offers through step 4's steps.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Mojo::File qw( path );
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( import_all_workflows join_tenant );
use Registry::DAO;
use Registry::DAO::Entitlement;
use Registry::DAO::Offer;
use Registry::DAO::OfferVersion;
use Registry::DAO::Project;
use Registry::DAO::Workflow;
use Registry::Utility::WorkflowProcessor;
use Registry::WorkflowStepClasses;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

import_all_workflows($dao);
Test::Registry::Fixtures::create_tenant( $dao, { name => 'Wheel Studio', slug => 'wheel_studio' } );
my $tenant_dao = Registry::DAO->new( url => $test_db->uri, schema => 'wheel_studio' );
my $tdb        = $tenant_dao->db;
import_all_workflows($tenant_dao);

my %user;
for my $role (qw( admin staff parent )) {
    $user{$role} = Test::Registry::Fixtures::create_user( $dao,
        { username => "wheel_$role", name => "Wheel \u$role", email => "$role\@wheel.test", user_type => $role } );
    join_tenant( $dao, $user{$role}, $role, 'wheel_studio' );
}

my $room = Test::Registry::Fixtures::create_location( $tdb, { name => 'Wheel room', slug => 'wheel-room' } );
my $elsewhere = Test::Registry::Fixtures::create_location( $dao->db, { name => 'Platform room', slug => 'platform-room' } );

my $workflow = $tenant_dao->find( Workflow => { slug => 'in-studio-class-setup' } );

sub steps_of ($w) {
    my @steps;
    for ( my $s = $w->first_step($tdb) ; $s ; $s = $s->next_step($tdb) ) { push @steps, $s }
    return @steps;
}

sub start ( $who = 'admin' ) {
    return Registry::WorkflowProcessor->new( dao => $tenant_dao )
        ->new_run( $workflow, { user => { id => $user{$who}->id, name => $user{$who}->name } } );
}

sub answer ( $run, $slug, $fields ) {
    return $run->process( $tdb, $workflow->get_step( $tdb, { slug => $slug } ), $fields );
}

sub errors_of ($result) { join ' ', ( $result->{errors} // [] )->@* }

# A fresh class name each call: projects names are unique.
sub class_name () { state $n = 0; 'Wheel throwing ' . ++$n }

# SACP's terms for a new class, with the given steps' fields overridden.
sub terms (%override) {
    my %terms = (
        'class'            => { class_mode => 'create', class_name => class_name(), location_id => $room->id,
                                seats_per_occurrence => 8 },
        'offer-basics'     => { offer_name => 'One seat' },
        'offer-price'      => { price_cents => 4500, currency => 'USD', units_per_acceptance => 1, per_booking_cap => 4 },
        'one-time-payment' => { one_time => 'offered' },
        'refund-policy'    => { refund => 'none' },
        'change-policy'    => { change => 'window', window_hours => 48, fee_cents => 1000, targets => 'same_offer' },
        'use-policy'       => { use => 'optional_attendance' },
        'expiry-policy'    => { expiry => 'end_of_occurrence' },
        'publish'          => { action => 'publish' },
    );
    $terms{$_} = { $terms{$_}->%*, $override{$_}->%* } for keys %override;
    return %terms;
}

# Starts a run as $who and submits every stored step, in order, even after
# one stays with an error. Returns the run and each step's result by slug.
sub walk ( $who, %by_step ) {
    my $run = start($who);
    my %result;
    $result{ $_->slug } = $run->process( $tdb, $_, $by_step{ $_->slug } // {} ) for grep { $_->slug ne 'complete' } steps_of($workflow);
    return ( $run, \%result );
}

sub published_count () {
    $tdb->query('SELECT count(*) FROM offer_versions WHERE published_at IS NOT NULL')->array->[0];
}

sub class_named ($name) { Registry::DAO::Project->find( $tdb, { name => $name } ) }

my $SACP_POLICIES = {
    refund => { kind => 'none' },
    change => { kind => 'window', window_hours => 48, fee_cents => 1000, targets => 'same_offer' },
    use    => { kind => 'optional_attendance' },
    expiry => { kind => 'end_of_occurrence' },
};

subtest 'the workflow is class then step 4 offer steps, admin only' => sub {
    ok $workflow, 'in-studio-class-setup is imported into the tenant' or return;
    is_deeply [ map { $_->slug } steps_of($workflow) ],
        [qw( class offer-basics offer-price one-time-payment refund-policy change-policy
             use-policy expiry-policy publish complete )],
        'a class step, then step 4\'s offer steps, with no resource or share-of-sales step';
    is_deeply $workflow->roles, ['admin'], 'its role entry is admin';
};

subtest 'admin run defines a class and creates no resource' => sub {
    my %t         = terms();
    my $resources = $tdb->query('SELECT count(*) FROM resources')->array->[0];
    my $run       = start();
    my $result    = answer( $run, 'class', $t{class} );
    is errors_of($result), '', 'the class step accepts' or return;

    my $class = class_named( $t{class}{class_name} );
    ok $class, 'a projects row is the class' or return;
    is $class->seats_per_occurrence, 8, 'with its default seats per occurrence';
    is $class->metadata->{location_id}, $room->id, 'and its location';
    is_deeply $run->data->{resource_choice}, { mode => 'class', class_project_id => $class->id },
        'the run covers the class, as step 4\'s resource step would';
    is $tdb->query('SELECT count(*) FROM resources')->array->[0], $resources, 'and no resource is created';

    answer( $run, 'class', $t{class} );
    is $tdb->query( 'SELECT count(*) FROM projects WHERE name LIKE ?', 'Wheel throwing%' )->array->[0], 1,
        'answering the class step again creates no second class';
};

subtest 'admin publishes the class offer with SACP terms' => sub {
    my %t = terms();
    my ( $run, $result ) = walk( admin => %t );
    is_deeply [ grep { length } map { errors_of( $result->{$_} ) } sort keys %$result ], [], 'every step accepts';
    my $class = class_named( $t{class}{class_name} ) or return fail 'no class';
    my $v = Registry::DAO::OfferVersion->find( $tdb, { id => $run->data->{published_offer_version_id} } );
    ok $v, 'an offer version is published' or return;
    ok $v->published_at, 'and is published';
    is $v->class_project_id,     $class->id, 'it covers the class';
    is $v->resource_id,          undef,      'not a resource of its own';
    is $v->price_cents,          4500,       'at the price';
    is $v->units_per_acceptance, 1,          'one seat per unit';
    is $v->per_booking_cap,      4,          'up to four per booking';
    is_deeply [ map { $_->{kind} } $v->payment_plans($tdb)->@* ], ['one_time'], 'paid once';
    is_deeply $v->policies, $SACP_POLICIES, 'under SACP\'s terms';

    my ( $again, $r2 ) = walk( admin => terms(
        'class'        => { class_mode => 'existing', class_project_id => $class->id },
        'offer-basics' => { offer_name => 'Couple (two seats)' },
        'offer-price'  => { units_per_acceptance => 2, per_booking_cap => 2 },
    ) );
    my $couple = Registry::DAO::OfferVersion->find( $tdb, { id => $again->data->{published_offer_version_id} // '' } );
    ok $couple, 'a second run adds another offer to the same class' or return diag explain $r2;
    is $couple->class_project_id,     $class->id, 'covering the same class';
    is $couple->units_per_acceptance, 2,          'two seats per unit';
    is $tdb->query( 'SELECT count(*) FROM projects WHERE name = ?', $class->name )->array->[0], 1, 'with no new class';
};

subtest 'staff cannot publish class offers' => sub {
    for my $who (qw( staff parent )) {
        my $before = published_count();
        my %t      = terms();
        my ( undef, $result ) = walk( $who => %t );
        like errors_of( $result->{class} ), qr/Only an administrator/, "the class step refuses $who";
        like errors_of( $result->{publish} ), qr/Only an administrator/, "and so does publish";
        ok !class_named( $t{class}{class_name} ), 'no class is defined';
        is published_count(), $before, 'nothing is published';
    }
};

subtest 'invalid capacity refused' => sub {
    for my $seats ( 0, -1, '1.5', 'abc', '', '1e3' ) {
        my %t   = terms( class => { seats_per_occurrence => $seats } );
        my $run = start();
        like errors_of( answer( $run, 'class', $t{class} ) ), qr/seats per occurrence/i, "seats '$seats' refused";
        ok !class_named( $t{class}{class_name} ), 'and no class is defined';
        ok !$run->data->{resource_choice}, 'nor chosen for the offer';
    }
};

subtest 'a duplicate class name is refused' => sub {
    my %t = terms();
    answer( start(), 'class', $t{class} );
    ok class_named( $t{class}{class_name} ), 'the first class is defined' or return;
    my $count = sub { $tdb->query( 'SELECT count(*) FROM projects WHERE name = ?', $t{class}{class_name} )->array->[0] };

    my $run = start();
    like errors_of( answer( $run, 'class', $t{class} ) ), qr/name already in use/, 'a second class of that name is refused';
    is $count->(), 1, 'and none is created';
    ok !$run->data->{resource_choice}, 'nor chosen for the offer';

    # In a caller's transaction the refusal leaves that transaction usable.
    my $tx = $tdb->begin;
    like errors_of( answer( start(), 'class', $t{class} ) ), qr/name already in use/, 'refused inside a transaction too';
    ok eval { $tdb->query('SELECT 1'); 1 }, 'and the caller\'s transaction is not aborted' or diag $@;
    undef $tx;
};

subtest 'an offer of another class is refused' => sub {
    my %a = terms( 'offer-basics' => { offer_name => 'Wheel drop-in' } );
    my ( $first ) = walk( admin => %a );
    my $v = Registry::DAO::OfferVersion->find( $tdb, { id => $first->data->{published_offer_version_id} // '' } )
        or return fail 'nothing published';
    my $count  = sub { $tdb->query( 'SELECT count(*) FROM offer_versions WHERE offer_id = ?', $v->offer_id )->array->[0] };
    my $before = $count->();

    my %b = terms( 'offer-basics' => { offer_id => $v->offer_id } );
    my ( $run, $result ) = walk( admin => %b );
    like errors_of( $result->{'offer-basics'} ), qr/Choose one of the offers for this class/,
        'a new version of another class\'s offer is refused';
    ok !$run->data->{offer_basics}, 'the run holds no offer';
    is $count->(), $before, 'no version of that offer is drafted or published';
    is Registry::DAO::Offer->find( $tdb, { id => $v->offer_id } )->current_version($tdb)->class_project_id,
        $v->class_project_id, 'it still covers its own class';

    my $listed = $workflow->get_step( $tdb, { slug => 'offer-basics' } )->prepare_template_data( $tdb, $run );
    ok !grep( { $_->id eq $v->offer_id } $listed->{offers}->@* ), 'and offer-basics does not list it for this class';
    my ( $own ) = walk( admin => %a, class => { class_mode => 'existing', class_project_id => $v->class_project_id },
        'offer-basics' => { offer_id => $v->offer_id } );
    ok $own->data->{published_offer_version_id}, 'its own class publishes a new version of it' or return;
    $listed = $workflow->get_step( $tdb, { slug => 'offer-basics' } )->prepare_template_data( $tdb, $own );
    ok grep( { $_->id eq $v->offer_id } $listed->{offers}->@* ), 'where offer-basics lists it';
};

subtest 'location required and from this tenant' => sub {
    for my $case ( [ blank => '' ], [ 'not an id' => 'nope' ], [ unknown => '00000000-0000-0000-0000-00000000abcd' ],
                   [ 'another schema\'s' => $elsewhere->id ] ) {
        my %t = terms( class => { location_id => $case->[1] } );
        like errors_of( answer( start(), 'class', $t{class} ) ), qr/Choose one of your locations/,
            "a $case->[0] location is refused";
        ok !class_named( $t{class}{class_name} ), 'and no class is defined';
    }
    like errors_of( answer( start(), 'class', { class_mode => 'existing', class_project_id => $elsewhere->id } ) ),
        qr/Choose one of your classes/, 'an existing class must be one of this tenant\'s classes';
};

# A run past the class step for a new class of 8 seats; returns it.
sub run_for_class_of_eight () {
    my %t   = terms();
    my $run = start();
    answer( $run, $_, $t{$_} ) for qw( class offer-basics );
    return $run;
}

subtest 'invalid seats per unit or cap refused' => sub {
    my $run = run_for_class_of_eight();
    my %t   = terms();
    for my $case ( [ units_per_acceptance => 0 ], [ units_per_acceptance => -1 ], [ units_per_acceptance => 9 ],
                   [ per_booking_cap => 0 ], [ per_booking_cap => -1 ] ) {
        my $result = answer( $run, 'offer-price', { $t{'offer-price'}->%*, @$case } );
        ok $result->{stay}, "$case->[0] $case->[1] stays";
        like errors_of($result), $case->[0] eq 'per_booking_cap' ? qr/per-booking cap/ : qr/Units per acceptance/,
            'with the reason';
        ok !$run->data->{offer_price}, 'and records no price';
    }
    is errors_of( answer( $run, 'offer-price', { $t{'offer-price'}->%*, units_per_acceptance => 8 } ) ), '',
        'all eight seats per unit is accepted';

    # Publish asks again: the class's seats lowered after the price step.
    my $before = published_count();
    answer( $run, $_, $t{$_} ) for qw( one-time-payment refund-policy change-policy use-policy expiry-policy );
    $tdb->update( 'projects', { seats_per_occurrence => 4 }, { id => $run->data->{resource_choice}{class_project_id} } );
    like errors_of( answer( $run, 'publish', $t{publish} ) ), qr/cannot exceed 4/, 'publish refuses units over the seats now';
    is published_count(), $before, 'and publishes nothing';
};

subtest 'blank price refused not zero' => sub {
    my $run = run_for_class_of_eight();
    my %t   = terms();
    for my $price ( '', ' ', '-100' ) {
        my $result = answer( $run, 'offer-price', { $t{'offer-price'}->%*, price_cents => $price } );
        like errors_of($result), qr/price/, "price '$price' is refused";
        ok !$run->data->{offer_price}, 'and no price is recorded, not even zero';
    }
    my $bare = answer( $run, 'offer-price', { %{ $t{'offer-price'} }{qw( currency units_per_acceptance per_booking_cap )} } );
    like errors_of($bare), qr/price/, 'a missing price is refused';
};

subtest 'invalid change window refused' => sub {
    my $run = run_for_class_of_eight();
    my %t   = terms();
    for my $hours ( -1, 'abc', '', '4.5' ) {
        my $result = answer( $run, 'change-policy', { $t{'change-policy'}->%*, window_hours => $hours } );
        like errors_of($result), qr/change window/, "window '$hours' is refused";
        ok !$run->data->{change_policy}, 'and no change policy is recorded';
    }
};

subtest 'published offer version update refused by database' => sub {
    my ( $run ) = walk( admin => terms() );
    my $id = $run->data->{published_offer_version_id} or return fail 'nothing published';
    for my $set ( 'price_cents = 1', q{policies = '{}'::jsonb} ) {
        my $ok = eval { $tdb->query( "UPDATE offer_versions SET $set WHERE id = ?", $id ); 1 };
        ok !$ok, "UPDATE ... SET $set is refused";
        like $@, qr/immutable once published/, 'as immutable';
    }
};

subtest 'price change publishes new version old unchanged' => sub {
    my %t = terms();
    my ( $run ) = walk( admin => %t );
    my $v1 = Registry::DAO::OfferVersion->find( $tdb, { id => $run->data->{published_offer_version_id} } )
        or return fail 'nothing published';
    my $row = sub ($id) {
        # Every term; superseded_at alone is set when a newer version replaces it.
        my $r = $tdb->query( q{SELECT * FROM offer_versions WHERE id = ?}, $id )->expand->hash;
        delete $r->{superseded_at};
        $r;
    };
    my $before = $row->( $v1->id );
    my $stamped = Registry::DAO::Entitlement->create( $tdb, {
        holder_user_id   => $tdb->insert( 'users', { username => 'stamped_booker' }, { returning => 'id' } )->hash->{id},
        offer_version_id => $v1->id, offer_id => $v1->offer_id,
        payment_plan_id => 'one_time', starts_at => '2026-01-01T00:00:00Z',
    } );

    my $class = class_named( $t{class}{class_name} );
    my ( $again ) = walk( admin => terms(
        'class'        => { class_mode => 'existing', class_project_id => $class->id },
        'offer-basics' => { offer_id => $v1->offer_id },
        'offer-price'  => { price_cents => 5000 },
    ) );
    my $v2 = Registry::DAO::OfferVersion->find( $tdb, { id => $again->data->{published_offer_version_id} // '' } );
    ok $v2, 'a new version is published' or return;
    isnt $v2->id, $v1->id, 'not the old one';
    is $v2->offer_id,    $v1->offer_id, 'of the same offer';
    is $v2->price_cents, 5000,          'at the new price';
    is Registry::DAO::Offer->find( $tdb, { id => $v1->offer_id } )->current_version($tdb)->id, $v2->id, 'and is current';
    is_deeply $row->( $v1->id ), $before, 'the earlier version is unchanged';
    ok $tdb->query( q{SELECT superseded_at IS NOT NULL FROM offer_versions WHERE id = ?}, $v1->id )->array->[0],
        q{and is only marked superseded};
    is $tdb->query( 'SELECT offer_version_id FROM entitlements WHERE id = ?', $stamped->id )->array->[0], $v1->id,
        'and what was stamped with it still names it';
};

subtest 'class setup steps all on allowlist' => sub {
    ok Registry::WorkflowStepClasses::is_allowed( $_->class ), $_->slug . ' names ' . $_->class . ', allowed'
        for steps_of($workflow);

    # A copy edited to name a class off the allowlist: import refuses it, and
    # a stored step changed around the DAO refuses to run.
    my $yaml = path('workflows/in-studio-class-setup.yml')->slurp
        =~ s/slug: in-studio-class-setup/slug: in-studio-class-setup-copy/r =~ s/name: In-studio Class Setup/name: Class setup copy/r;
    my $bad = $yaml =~ s/Registry::DAO::WorkflowSteps::ClassBasics/IO::Socket::INET/r;
    ok !eval { Registry::DAO::Workflow->from_yaml( $tenant_dao, $bad ); 1 }, 'an edited copy naming IO::Socket::INET is refused';
    like $@, qr/not an allowed workflow step class/, 'as not allowed';

    my $copy = Registry::DAO::Workflow->from_yaml( $tenant_dao, $yaml );
    $tdb->query( q{UPDATE workflow_steps SET class = 'IO::Socket::INET' WHERE workflow_id = ? AND slug = 'class'}, $copy->id );
    my $before = $tdb->query('SELECT count(*) FROM projects')->array->[0];
    ok !eval { $copy->get_step( $tdb, { slug => 'class' } ); 1 }, 'the stored copy\'s step refuses to load';
    like $@, qr/not an allowed workflow step class/, 'as not allowed';
    is $tdb->query('SELECT count(*) FROM projects')->array->[0], $before, 'and defines nothing';
};

done_testing;
