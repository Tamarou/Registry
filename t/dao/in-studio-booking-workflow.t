#!/usr/bin/env perl
# ABOUTME: The public in-studio-booking workflow through the real WorkflowProcessor: occurrence, offer and count, account, hold.
# ABOUTME: Holding takes count x seats per unit for a limited time and parks the run at payment; every refusal holds nothing.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( import_all_workflows );
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO;
use Registry::DAO::Offer;
use Registry::DAO::Project;
use Registry::DAO::Resource;
use Registry::DAO::Workflow;
use Registry::Utility::WorkflowProcessor;
use Registry::WorkflowStepClasses;
use Registry::PriceOps::Hold;
use Registry::Terms;

# What the offer page posts when the booker ticks the terms box.
my %AGREE = ( agree_to_terms => 1, terms_version_shown => Registry::Terms::VERSION );

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

my $SLUG = 'wheel_studio';
import_all_workflows($dao);
Test::Registry::Fixtures::create_tenant( $dao, { name => 'Wheel Studio', slug => $SLUG } );
my $tenant_dao = Registry::DAO->new( url => $test_db->uri, schema => $SLUG );
my $tdb        = $tenant_dao->db;
import_all_workflows($tenant_dao);

# The booker and the teacher, as users of the studio's schema.
my %user;
for my $who (qw( booker teacher )) {
    $user{$who} = Test::Registry::Fixtures::create_user( $dao,
        { username => "wheel_$who", name => "Wheel \u$who", email => "$who\@wheel.test", user_type => 'parent' } );
    $dao->db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)', $SLUG, $user{$who}->id );
}

my $room = Test::Registry::Fixtures::create_location( $tdb,
    { name => 'Wheel room', slug => 'wheel-room', time_zone => 'America/New_York' } );

my $workflow = $tenant_dao->find( Workflow => { slug => 'in-studio-booking' } );

# A class of $seats seats per occurrence, with one published occurrence
# starting $when (SQL, relative to now) and its seats.
sub occurrence ( $seats = 10, $when = q{now() + interval '7 days'}, $handle = $tdb, $location = $room ) {
    state $n = 0;
    ++$n;
    my $class = Registry::DAO::Project->create( $handle,
        { name => "Throwing $n", seats_per_occurrence => $seats, metadata => { location_id => $location->id } } );
    my $event = $handle->query( qq{
        INSERT INTO events (project_id, location_id, teacher_id, time, duration, capacity, status)
        VALUES (?, ?, ?, $when, 90, ?, 'published') RETURNING id
    }, $class->id, $location->id, $user{teacher}->id, $seats )->array->[0];
    return ( $class, Registry::DAO::Resource->for_occurrence( $handle, $event ) );
}

# A published offer for $class: $name, with %terms over offer_terms' defaults.
sub offer ( $class, $name = 'One seat', %terms ) {
    return Registry::DAO::Offer->create( $tdb, { name => $name } )
        ->draft( $tdb, offer_terms( undef, class_project_id => $class->id, per_booking_cap => 3,
            policies => { refund => { kind => 'none' } }, %terms ) )
        ->publish($tdb);
}

sub start () {
    my $u = $user{booker};
    return Registry::WorkflowProcessor->new( dao => $tenant_dao )
        ->new_run( $workflow, { user => { id => $u->id, name => $u->name }, user_id => $u->id } );
}

sub step ($slug) { $workflow->get_step( $tdb, { slug => $slug } ) }

sub errors_of ($result) { join ' ', ( ref $result eq 'HASH' ? $result->{errors} // [] : [] )->@* }

# Walks a fresh run to the hold step's result: occurrence, offer and count,
# the signed-in booker. Returns the run and each step's result by slug.
sub book ( $resource, $version, $count ) {
    my $run = start();
    my %r;
    $r{occurrence} = $run->process( $tdb, step('occurrence'), { occurrence_id => $resource->id } );
    $r{offer}      = $run->process( $tdb, step('offer'), { offer_version_id => $version->id, count => $count, %AGREE } );
    $r{account}    = $run->process( $tdb, step('account'), { action => 'continue_logged_in' } );
    $r{hold}       = $run->process( $tdb, step('hold'), {} );
    return ( $run, \%r );
}

sub live_holds ($resource) {
    my $live = Registry::PriceOps::Hold->live_sql('holds');
    return $tdb->query( "SELECT count(*) FROM holds WHERE resource_id = ? AND $live", $resource->id )->array->[0];
}

sub reload ($run) { $tenant_dao->find( WorkflowRun => { id => $run->id } ) }

subtest 'the workflow is public, with the design\'s steps' => sub {
    ok $workflow, 'in-studio-booking is imported into the tenant' or return;
    my @slugs;
    for ( my $s = $workflow->first_step($tdb) ; $s ; $s = $s->next_step($tdb) ) { push @slugs, $s->slug }
    is_deeply \@slugs, [qw( occurrence offer account hold payment )], 'occurrence, offer, account, hold, then payment';
    ok $workflow->public, 'it carries the public mark';
    ok Registry::WorkflowStepClasses::is_allowed("Registry::DAO::WorkflowSteps::$_"), "$_ is on the allowlist"
        for qw( ChooseOccurrence ChooseOfferAndUnits HoldSeats );
};

subtest 'two units of a two-seat offer hold four seats for a limited time and park at payment' => sub {
    my ( $class, $seats ) = occurrence(10);
    my $version = offer( $class, 'Couple', units_per_acceptance => 2, price_cents => 4500 );
    my ( $run, $r ) = book( $seats, $version, 2 );
    is errors_of( $r->{$_} ), '', "the $_ step is accepted" for qw( occurrence offer hold );

    my ($hold) = Registry::PriceOps::Hold->find( $tdb, { workflow_run_id => $run->id }, 'id' );
    ok $hold, 'a hold is placed for the run' or return;
    is $hold->resource_id, $seats->id, 'on the chosen occurrence';
    is $hold->units, 4, 'for 2 x 2 seats';
    ok $tdb->query( q{SELECT ?::timestamptz BETWEEN now() + interval '14 minutes' AND clock_timestamp() + interval '15 minutes'},
        $hold->expires_at )->array->[0], 'expiring 15 minutes after it is placed';
    is $seats->free_units($tdb), 6, 'leaving 6 seats';

    $run = reload($run);
    is $run->next_step($tdb)->slug, 'payment', 'the run is parked at payment';
    is_deeply $run->data->{owed_payment}, {
        offer_version_id => $version->id,
        payment_plan     => 'pay',
        amount_cents     => 9000,
        description      => 'Couple x 2',
        purpose          => 'booking',
        hold_id          => $hold->id,
    }, 'and owes 2 x the price against the hold';
};

sub run_holds ($run) {
    return $tdb->query( q{SELECT count(*) FROM holds WHERE workflow_run_id = ? AND state = 'held'}, $run->id )
        ->array->[0];
}

# Moves every hold of $run's to have lapsed a minute ago.
sub lapse ($run) {
    $tdb->query( q{UPDATE holds SET expires_at = clock_timestamp() - interval '1 minute' WHERE workflow_run_id = ?},
        $run->id );
}

subtest 'units over the per-booking cap refused' => sub {
    my ( $class, $seats ) = occurrence(10);
    my $version = offer( $class, 'Seat', per_booking_cap => 3 );
    my ( $run, $r ) = book( $seats, $version, 4 );
    like errors_of( $r->{offer} ), qr/at most 3 per booking/, 'four of a cap of three is refused with a message';
    is run_holds($run), 0, 'and holds nothing';

    # The run's count written past the offer step: the hold step asks again.
    ( $run, $r ) = book( $seats, $version, 3 );
    is errors_of( $r->{hold} ), '', 'the cap itself is held';
    $run->update_data( $tdb, { booking_count => 4 } );
    like errors_of( $run->process( $tdb, step('hold'), {} ) ), qr/at most 3 per booking/,
        'a count over the cap reaching the hold step is refused';
    is run_holds($run), 0, 'and gives back what the run held';
    is $seats->free_units($tdb), 10, 'every seat is free';
};

subtest 'full occurrence refused' => sub {
    my ( $class, $seats ) = occurrence(2);
    my $version = offer( $class, 'Seat' );
    my ( $first, $r ) = book( $seats, $version, 2 );
    is errors_of( $r->{hold} ), '', 'two seats of two are held';

    ( my $run, $r ) = book( $seats, $version, 1 );
    like errors_of( $r->{occurrence} ), qr/full/, 'choosing the full occurrence is refused with a message';
    ok !grep( { $_->{id} eq $seats->id } step('occurrence')->prepare_template_data( $tdb, $run )->{occurrences}->@* ),
        'and it is not listed';
    is run_holds($run), 0, 'and nothing is held';

    # Chosen with room, filled by another run before this one holds.
    my ( $c2, $two ) = occurrence(2);
    my $v2 = offer( $c2, 'Seat' );
    $run = start();
    $run->process( $tdb, step('occurrence'), { occurrence_id => $two->id } );
    $run->process( $tdb, step('offer'), { offer_version_id => $v2->id, count => 1, %AGREE } );
    $run->process( $tdb, step('account'), { action => 'continue_logged_in' } );
    book( $two, $v2, 2 );
    like errors_of( $run->process( $tdb, step('hold'), {} ) ), qr/no longer has room for 1/,
        'holding in an occurrence filled meanwhile is refused';
    is run_holds($run), 0, 'and holds nothing';
    ok !reload($run)->data->{owed_payment}, 'and owes nothing';
};

subtest 'expired hold frees its seats' => sub {
    my ( $class, $seats ) = occurrence(4);
    my $version = offer( $class, 'Seat', per_booking_cap => 4 );
    my ($run) = book( $seats, $version, 4 );
    is $seats->free_units($tdb), 0, 'four of four seats are held';
    lapse($run);
    is $seats->free_units($tdb), 4, 'once the hold lapses all four are free';
    my ( $other, $r ) = book( $seats, $version, 4 );
    is errors_of( $r->{hold} ), '', 'and another booking holds them';
    is run_holds($other), 1, 'with its own hold';
};

sub entitlements_on ($resource) {
    return $tdb->query( 'SELECT count(*) FROM entitlement_units WHERE resource_id = ?', $resource->id )->array->[0];
}

# A run that chose $resource and $count of $version and signed in, before the hold step.
sub chosen ( $resource, $version, $count ) {
    my $run = start();
    $run->process( $tdb, step('occurrence'), { occurrence_id => $resource->id } );
    $run->process( $tdb, step('offer'), { offer_version_id => $version->id, count => $count, %AGREE } );
    $run->process( $tdb, step('account'), { action => 'continue_logged_in' } );
    return $run;
}

subtest 'offer from another class refused' => sub {
    my ( $class, $seats ) = occurrence(10);
    my ( $other_class ) = occurrence(10);
    offer( $class, 'Seat' );
    my $other = offer( $other_class, 'Other seat' );
    my ( $run, $r ) = book( $seats, $other, 1 );
    like errors_of( $r->{offer} ), qr/Choose one of the listed offers/, 'another class\'s offer is refused';
    is run_holds($run), 0, 'and nothing is held';

    # Written into the run past the offer step: the hold step asks again.
    $run = chosen( $seats, offer( $class, 'Seat again' ), 1 );
    $run->update_data( $tdb, { booking_offer_version_id => $other->id } );
    like errors_of( $run->process( $tdb, step('hold'), {} ) ), qr/Choose one of the listed offers/,
        'and so is one reaching the hold step';
    is run_holds($run), 0, 'which holds nothing';
};

subtest 'superseded offer version refused' => sub {
    my ( $class, $seats ) = occurrence(10);
    my $v1    = offer( $class, 'Seat' );
    my $offer = Registry::DAO::Offer->find( $tdb, { id => $v1->offer_id } );
    my $v2    = $offer->draft( $tdb, offer_terms( undef, class_project_id => $class->id, per_booking_cap => 3 ) )
        ->publish($tdb);
    my ( $run, $r ) = book( $seats, $v1, 1 );
    like errors_of( $r->{offer} ), qr/Choose one of the listed offers/, 'the superseded version is refused';
    is run_holds($run), 0, 'and nothing is held';

    my $draft = $offer->draft( $tdb, offer_terms( undef, class_project_id => $class->id, per_booking_cap => 3 ) );
    ( $run, $r ) = book( $seats, $draft, 1 );
    like errors_of( $r->{offer} ), qr/Choose one of the listed offers/, 'an unpublished version is refused';

    # Superseded after it was chosen, before the seats are held.
    $run = chosen( $seats, $draft->publish($tdb), 1 );
    $offer->draft( $tdb, offer_terms( undef, class_project_id => $class->id, per_booking_cap => 3 ) )->publish($tdb);
    like errors_of( $run->process( $tdb, step('hold'), {} ) ), qr/Choose one of the listed offers/,
        'a version superseded before the hold is refused there';
    is run_holds($run), 0, 'holding nothing';
};

subtest 'past occurrence refused' => sub {
    my ( $class, $seats ) = occurrence( 10, q{now() - interval '1 hour'} );
    my $version = offer( $class, 'Seat' );
    my ( $run, $r ) = book( $seats, $version, 1 );
    like errors_of( $r->{occurrence} ), qr/Choose one of the listed classes/, 'an occurrence under way is refused';
    ok !grep( { $_->{id} eq $seats->id } step('occurrence')->prepare_template_data( $tdb, $run )->{occurrences}->@* ),
        'and not listed';

    # Started after it was chosen, before the seats are held (G4).
    my ( $later_class, $later ) = occurrence(10);
    $run = chosen( $later, offer( $later_class, 'Seat' ), 1 );
    $tdb->query( q{UPDATE events SET time = now() - interval '1 minute' WHERE id = ?}, $later->event_id );
    like errors_of( $run->process( $tdb, step('hold'), {} ) ), qr/Choose one of the listed classes/,
        'one that started before the hold is refused there';
    is run_holds($run), 0, 'holding nothing';
    is entitlements_on($_), 0, 'and no booking is granted' for $seats, $later;
};

subtest 'closed occurrence refused' => sub {
    my ( $class, $seats ) = occurrence(10);
    my $version = offer( $class, 'Seat' );
    my $run = chosen( $seats, $version, 1 );
    $tdb->query( q{UPDATE events SET status = 'closed' WHERE id = ?}, $seats->event_id );
    like errors_of( $run->process( $tdb, step('hold'), {} ) ), qr/Choose one of the listed classes/,
        'an occurrence closed before the hold is refused (G4)';
    is run_holds($run), 0, 'holding nothing';
    is entitlements_on($seats), 0, 'and granting nothing';
    my ( $closed_run, $r ) = book( $seats, $version, 1 );
    like errors_of( $r->{occurrence} ), qr/Choose one of the listed classes/, 'and it cannot be chosen';
};

subtest 'invalid unit count refused' => sub {
    my ( $class, $seats ) = occurrence(10);
    my $version = offer( $class, 'Seat' );
    for my $count ( 0, -1, 1.5, '2abc', '', ' 1', '01x' ) {
        my ( $run, $r ) = book( $seats, $version, $count );
        like errors_of( $r->{offer} ), qr/whole number of at least one/, "a count of '$count' is refused";
        is run_holds($run), 0, 'and holds nothing';
    }
    my ( $run, $r ) = book( $seats, $version, undef );
    like errors_of( $r->{offer} ), qr/whole number of at least one/, 'so is no count';
    is $seats->free_units($tdb), 10, 'every seat is free';
};

subtest 'expired hold cannot proceed to payment' => sub {
    my ( $class, $seats ) = occurrence(2);
    my $version = offer( $class, 'Seat' );
    my ($run) = book( $seats, $version, 2 );
    my $stale = reload($run)->data->{owed_payment}{hold_id};
    lapse($run);
    $run = reload($run);
    like errors_of( $run->process( $tdb, step('payment'), {} ) ), qr/lapsed\. Nothing has been charged/,
        'payment on the lapsed hold is refused';
    is $tdb->query( q{SELECT count(*) FROM payments WHERE metadata->>'workflow_run_id' = ?}, $run->id )->array->[0], 0,
        'and starts no payment';

    is errors_of( $run->process( $tdb, step('hold'), {} ) ), '', 'holding again while the seats remain is accepted';
    my $owed = reload($run)->data->{owed_payment};
    isnt $owed->{hold_id}, $stale, 'on a new hold';
    is $tdb->query( q{SELECT state FROM holds WHERE id = ?}, $stale )->array->[0], 'released', 'the stale one released';
    is run_holds($run), 1, 'one hold for the run';

    lapse($run);
    book( $seats, $version, 2 );
    like errors_of( $run->process( $tdb, step('hold'), {} ) ), qr/no longer has room for 2/,
        'with the seats taken meanwhile it is refused';
    is run_holds($run), 0, 'holding nothing';
    $run = reload($run);
    ok !$run->data->{owed_payment}, 'and owing nothing';
    like errors_of( $run->process( $tdb, step('payment'), {} ) ), qr/Nothing is owed/, 'so payment is refused';
};

subtest 'resubmitted hold step holds once' => sub {
    my ( $class, $seats ) = occurrence(10);
    my $version = offer( $class, 'Seat' );
    my ($run) = book( $seats, $version, 2 );
    my $first = reload($run)->data->{owed_payment}{hold_id};
    is errors_of( $run->process( $tdb, step('hold'), {} ) ), '', 'a second submit is accepted';
    is run_holds($run), 1, 'leaving one hold';
    is reload($run)->data->{owed_payment}{hold_id}, $first, 'the same one';
    is $seats->free_units($tdb), 8, 'for two seats, not four';
};

subtest 'other tenant occurrence not found' => sub {
    Test::Registry::Fixtures::create_tenant( $dao, { name => 'Kiln Studio', slug => 'kiln_studio' } );
    my $kdb  = Registry::DAO->new( url => $test_db->uri, schema => 'kiln_studio' )->db;
    $dao->db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)', 'kiln_studio', $user{teacher}->id );
    my $kiln = Test::Registry::Fixtures::create_location( $kdb,
        { name => 'Kiln room', slug => 'kiln-room', time_zone => 'America/New_York' } );
    my ( $kclass, $kseats ) = occurrence( 10, q{now() + interval '7 days'}, $kdb, $kiln );
    Registry::DAO::Offer->create( $kdb, { name => 'Kiln seat' } )
        ->draft( $kdb, offer_terms( undef, class_project_id => $kclass->id, per_booking_cap => 3 ) )->publish($kdb);

    my $run = start();
    like errors_of( $run->process( $tdb, step('occurrence'), { occurrence_id => $kseats->id } ) ),
        qr/Choose one of the listed classes/, 'another tenant\'s occurrence is not found';
    # Everything else in place, so only the occurrence can refuse it.
    $run->update_data( $tdb, { booking_occurrence_id => $kseats->id, agreed_terms_version => Registry::Terms::VERSION } );
    is_deeply step('offer')->prepare_template_data( $tdb, $run )->{offers}, [], 'and has no offers here';
    like errors_of( $run->process( $tdb, step('hold'), {} ) ), qr/Choose one of the listed classes/,
        'nor is it held when written into the run';
    is $kdb->query( 'SELECT count(*) FROM holds' )->array->[0], 0, 'nothing is held in the other tenant';
    is run_holds($run), 0, 'or here';
};

subtest 'booking refused without agreeing to terms' => sub {
    my ( $class, $seats ) = occurrence(10);
    my $version = offer( $class, 'Seat' );
    for my $form ( {}, { agree_to_terms => 1 }, { agree_to_terms => 1, terms_version_shown => 'v0' },
                   { terms_version_shown => Registry::Terms::VERSION } ) {
        my $run = start();
        $run->process( $tdb, step('occurrence'), { occurrence_id => $seats->id } );
        my $r = $run->process( $tdb, step('offer'), { offer_version_id => $version->id, count => 1, %$form } );
        like errors_of($r), qr/terms of service/, 'the offer step is refused with a message';
        $run = reload($run);
        is $run->next_step($tdb)->slug, 'offer', 'and stays on the offer page';
        ok !$run->data->{agreed_terms_version}, 'recording no agreement';
    }
};

subtest 'no hold without agreed terms' => sub {
    my ( $class, $seats ) = occurrence(10);
    my $version = offer( $class, 'Seat' );
    my $run = chosen( $seats, $version, 1 );
    is reload($run)->data->{agreed_terms_version}, Registry::Terms::VERSION, 'an agreeing booker is recorded';
    $run->update_data( $tdb, { agreed_terms_version => undef } );
    like errors_of( $run->process( $tdb, step('hold'), {} ) ), qr/Agree to the terms of service/,
        'a run reaching the hold step with no agreement is refused';
    is run_holds($run), 0, 'and holds nothing';
    ok !reload($run)->data->{owed_payment}, 'and owes nothing';
};

done_testing;
