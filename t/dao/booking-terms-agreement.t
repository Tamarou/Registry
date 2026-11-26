#!/usr/bin/env perl
# ABOUTME: A booker agrees to the /terms version being served, recorded on the run and stamped on the booking.
# ABOUTME: The stamp is set at insert and never changes; agreeing to a version no longer served is refused.
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
use Registry::DAO::Entitlement;
use Registry::DAO::Tenant;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::PriceOps::Hold;
use Registry::Terms;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $SLUG = 'terms_studio';
Registry::DAO::Tenant->create( $db, { name => 'Terms Studio', slug => $SLUG } );
$db->query( 'SELECT clone_schema(dest_schema => ?)', $SLUG );
my $studio = Registry::DAO->new( url => $dao->url, schema => $SLUG )->db;

my $made = 0;

sub person () {
    return $studio->insert( 'users', { username => 'p-' . ++$made }, { returning => 'id' } )->hash->{id};
}

sub run () {
    my $workflow = Registry::DAO::Workflow->create( $studio,
        { slug => 'book-' . ++$made, name => "Book $made", public => 1 } );
    return $workflow->new_run($studio);
}

sub fresh ($run) { Registry::DAO::WorkflowRun->find( $studio, { id => $run->id } ) }

# One occurrence of 10 seats and a published class offer version covering it.
sub occurrence () {
    my $class = $studio->insert( 'projects', { name => 'Class ' . ++$made, slug => "class-$made" },
        { returning => 'id' } )->hash->{id};
    my $room = $studio->insert( 'locations',
        { name => "Room $made", slug => "room-$made", time_zone => 'America/New_York' },
        { returning => 'id' } )->hash->{id};
    my $event = $studio->insert( 'events', {
        project_id => $class, location_id => $room, teacher_id => person(),
        time       => '2099-03-01T10:00:00Z', duration => 90, capacity => 10,
    }, { returning => 'id' } )->hash->{id};
    my $version = Registry::DAO::Offer->create( $studio, { name => "Wheel class $made" } )
        ->draft( $studio, offer_terms( undef, class_project_id => $class, per_booking_cap => 10 ) )
        ->publish($studio);
    return ( $version, Registry::DAO::Resource->for_occurrence( $studio, $event ) );
}

# The booking path end to end, as CompleteBooking converts it: a hold for the
# run, converted into the booker's entitlement stamped with the run's agreement.
sub book ($run) {
    my ( $version, $seats ) = occurrence();
    my $hold = Registry::PriceOps::Hold->place( $studio, {
        resource_id     => $seats->id,
        units           => 1,
        workflow_run_id => $run->id,
        expires_at      => \"clock_timestamp() + interval '15 minutes'",
    } );
    return $hold->convert( $studio, {
        holder_user_id   => person(),
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
        starts_at        => '2020-01-01T00:00:00Z',
        terms_version    => fresh($run)->data->{agreed_terms_version},
    } );
}

my %AGREED = ( agree_to_terms => 1, terms_version_shown => Registry::Terms::VERSION );

subtest 'booking records the terms version agreed to' => sub {
    my $run = run();
    is Registry::Terms::record_agreement( $studio, $run, {%AGREED} ), undef, 'agreeing is not refused';
    is fresh($run)->data->{agreed_terms_version}, Registry::Terms::VERSION,
        'the run records the version being served';
    my $booking = book($run);
    is Registry::DAO::Entitlement->find( $studio, { id => $booking->id } )->terms_version,
        Registry::Terms::VERSION, 'and the booking carries it';
};

subtest 'booking without agreeing refused' => sub {
    for my $form ( {}, { terms_version_shown => Registry::Terms::VERSION }, { %AGREED, agree_to_terms => '' } ) {
        my $run = run();
        like Registry::Terms::record_agreement( $studio, $run, $form ), qr/agree to the terms/i,
            'refused with a message';
        ok !exists fresh($run)->data->{agreed_terms_version}, 'and nothing is recorded';
    }
};

subtest 'agreement to terms no longer served refused' => sub {
    for my $shown ( undef, 'v0-older', [ Registry::Terms::VERSION ] ) {
        my $run = run();
        like Registry::Terms::record_agreement( $studio, $run, { %AGREED, terms_version_shown => $shown } ),
            qr/terms .*changed/i, 'refused with a message';
        ok !exists fresh($run)->data->{agreed_terms_version}, 'and nothing is recorded';
    }
};

subtest 'terms version cannot change after booking' => sub {
    my $run = run();
    Registry::Terms::record_agreement( $studio, $run, {%AGREED} );
    my $booking = book($run);
    throws_ok {
        $studio->update( 'entitlements', { terms_version => 'v2' }, { id => $booking->id } )
    } qr/keeps the terms version/, 'changing it is refused';
    throws_ok {
        $studio->update( 'entitlements', { terms_version => undef }, { id => $booking->id } )
    } qr/keeps the terms version/, 'and so is clearing it';
};

subtest 'blank terms version refused' => sub {
    my $run = run();
    $run->update_data( $studio, { agreed_terms_version => '' } );
    throws_ok { book($run) } qr/entitlements_terms_version_check/, 'an empty version is not a version';
};

done_testing;
