#!/usr/bin/env perl
# ABOUTME: session-setup's instalment and missed-payment steps, driven on a session run, and what publishing makes of them.
# ABOUTME: A version offering instalments says what a missed one does, and its last payment falls by the session's last day.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( days_from_now import_all_workflows join_tenant );
use Registry::DAO;
use Registry::DAO::OfferVersion;
use Registry::DAO::Workflow;
use Registry::Utility::WorkflowProcessor;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
import_all_workflows($dao);

my %user;
for my $role (qw( admin staff )) {
    $user{$role} = Test::Registry::Fixtures::create_user( $dao,
        { username => "plans_$role", name => "Plans \u$role", email => "$role\@plans.test", user_type => $role } );
    join_tenant( $dao, $user{$role}, $role );
}
my $field = Test::Registry::Fixtures::create_location( $db, { name => 'Plans field', slug => 'plans-field' } );

my $workflow = $dao->find( Workflow => { slug => 'session-setup' } );
sub step ($slug) { $workflow->get_step( $db, { slug => $slug } ) }
# session-setup gains its publish step later (plan Task 13); offer-publishing's
# publish step is the same class, called on the session run.
my $publish = $dao->find( Workflow => { slug => 'offer-publishing' } )->get_step( $db, { slug => 'publish' } );

# A session run with one session from $first to $last, every weekday, and the
# offer terms the later steps record, so only the payment steps are left.
sub session_run ( $name, $first, $last ) {
    my $run = Registry::WorkflowProcessor->new( dao => $dao )
        ->new_run( $workflow, { user => { id => $user{admin}->id, name => $user{admin}->name } } );
    $run->process( $db, step('program'), { program_mode => 'create', program_name => "$name program", location_id => $field->id } );
    $run->process( $db, step('sessions'), {
        action => 'add', name => $name, first_day => $first, last_day => $last, weekdays => [ 1 .. 7 ],
        start  => '09:00', minutes => 420, capacity => 12, waitlist => 'none', teacher_id => $user{staff}->id,
    } );
    $run->process( $db, step('sessions'), { action => 'continue' } );
    $run->update_data( $db, {
        offer_basics  => { resource_id => $run->data->{sessions}[0], offer_name => "$name offer" },
        offer_price   => { price_cents => 30000, currency => 'usd', units_per_acceptance => 1, per_booking_cap => 1 },
        refund_policy => { kind => 'none' },
        change_policy => { kind => 'none' },
        use_policy    => { use => 'optional_attendance' },
        expiry_policy => { expiry => 'end_of_occurrence' },
    } );
    return $run;
}

sub errors_of ($result) { join ' ', ( ( ref $result eq 'HASH' ? $result->{errors} : undef ) // [] )->@* }

subtest 'a grace policy of seven days is published' => sub {
    my $run = session_run( 'Grace term', days_from_now(7), days_from_now(70) );
    my $plan = $run->process( $db, step('instalment-payment'),
        { instalments => 'offered', count => 2, cadence => 'weekly', surcharge_pct => '5' } );
    is errors_of($plan), '', 'the instalment step accepts weekly x2';
    is_deeply $run->data->{instalment_payment},
        { id => 'parts', count => 2, cadence => 'weekly', surcharge_pct => '5' }, 'and records the plan';

    ok !step('missed-payment-policy')->nothing_to_ask( $db, $run ), 'the missed-payment step asks when instalments are offered';
    my $missed = $run->process( $db, step('missed-payment-policy'), { missed_payment => 'grace', grace_days => 7 } );
    is errors_of($missed), '', 'the missed-payment step accepts grace of seven days';
    is_deeply $run->data->{missed_payment_policy}, { kind => 'grace', days => 7 }, 'and records it';

    my $result = $publish->process( $db, { action => 'publish' }, $run );
    is errors_of($result), '', 'it publishes';
    my $version = Registry::DAO::OfferVersion->find( $db, { id => $result->{published_offer_version_id} } );
    ok $version, 'a version';
    is_deeply $version->policies->{missed_payment}, { kind => 'grace', days => 7 }, 'whose missed_payment is grace of seven days';
    my ($parts) = grep { $_->{kind} eq 'instalments' } $version->payment_plans($db)->@*;
    is_deeply [ $parts->@{qw( id count cadence )} ], [ 'parts', 2, 'weekly' ], 'and which offers the instalments';
    is 0 + $parts->{surcharge_pct}, 5, 'with their surcharge';
};

subtest 'the missed-payment step is skipped without instalments' => sub {
    my $run = session_run( 'Plain term', days_from_now(7), days_from_now(70) );
    $run->update_data( $db, { missed_payment_policy => { kind => 'end' } } );    # an earlier answer
    $run->process( $db, step('instalment-payment'), { instalments => 'declined' } );
    is $run->data->{instalment_payment}, undef, 'declining records no instalment plan';
    ok step('missed-payment-policy')->nothing_to_ask( $db, $run ), 'the missed-payment step has nothing to ask';
    my $skipped = $run->process( $db, step('missed-payment-policy'), {} );
    is errors_of($skipped), '', 'and passes with no answer';
    ok exists $run->data->{missed_payment_policy}, 'missed_payment_policy is recorded';
    is $run->data->{missed_payment_policy}, undef, 'as undef';
};

sub versions_of ($name) {
    return $db->query( 'SELECT count(*) FROM offer_versions v JOIN offers o ON o.id = v.offer_id WHERE o.name = ?',
        "$name offer" )->array->[0];
}

subtest 'instalments without a missed-payment policy are refused' => sub {
    my $run = session_run( 'Unsaid term', days_from_now(7), days_from_now(70) );
    $run->process( $db, step('instalment-payment'), { instalments => 'offered', count => 2, cadence => 'monthly' } );
    ok $run->data->{instalment_payment}, 'the run offers instalments';
    is $run->data->{missed_payment_policy}, undef, 'and never reached the missed-payment step';
    is errors_of( $publish->process( $db, { action => 'publish' }, $run ) ),
        'Choose what happens when an instalment is missed', 'publishing is refused';
    is versions_of('Unsaid term'), 0, 'and writes no version';
    is errors_of( $run->process( $db, step('missed-payment-policy'), {} ) ),
        'Choose what happens when an instalment is missed', 'the step itself refuses no answer';
};

subtest 'a weekly plan of four over a one week camp is refused' => sub {
    my ( $first, $last ) = ( days_from_now(1), days_from_now(7) );
    my $run  = session_run( 'Camp week', $first, $last );
    my $why  = "A weekly plan of 4 payments bought today would end after $last, the last day of Camp week";
    my $plan = { instalments => 'offered', count => 4, cadence => 'weekly' };
    is errors_of( $run->process( $db, step('instalment-payment'), $plan ) ), $why, 'the instalment step refuses it';
    is $run->data->{instalment_payment}, undef, 'and records no plan';

    # The offer's session chosen after the plan, as a later step may: publish asks again.
    $run->update_data( $db, {
        instalment_payment    => { id => 'parts', count => 4, cadence => 'weekly', surcharge_pct => undef },
        missed_payment_policy => { kind => 'end' },
    } );
    is errors_of( $publish->process( $db, { action => 'publish' }, $run ) ), $why, 'publishing is refused';
    is versions_of('Camp week'), 0, 'and writes no version';
};

subtest 'the instalment step checks the run\'s sessions before an offer names one' => sub {
    my ( $first, $last ) = ( days_from_now(1), days_from_now(7) );
    my $run = session_run( 'Early camp', $first, $last );
    $run->update_data( $db, { offer_basics => undef } );    # as session-setup has it: no offer step yet
    is errors_of( $run->process( $db, step('instalment-payment'), { instalments => 'offered', count => 4, cadence => 'weekly' } ) ),
        "A weekly plan of 4 payments bought today would end after $last, the last day of Early camp",
        'a weekly plan of four over the run\'s one week camp is refused at the step';
    is $run->data->{instalment_payment}, undef, 'and records no plan';
};

subtest 'publish refuses a malformed missed-payment policy' => sub {
    my $run = session_run( 'Malformed term', days_from_now(7), days_from_now(70) );
    $run->process( $db, step('instalment-payment'), { instalments => 'offered', count => 2, cadence => 'weekly' } );
    for my $case (
        [ { kind => 'grace' },                'a grace with no days' ],
        [ { kind => 'grace', days => 0 },     'a grace of zero days' ],
        [ { kind => 'grace', days => 10000 }, 'a grace of 10000 days' ],
        [ { kind => 'forgive' },              'an unknown kind' ],
        [ { kind => 'end', days => 7 },       'days on a kind that has none' ],
    ) {
        $run->update_data( $db, { missed_payment_policy => $case->[0] } );
        like errors_of( $publish->process( $db, { action => 'publish' }, $run ) ),
            qr/\A(?:Choose what happens when an instalment is missed|A grace period is a whole number of days from 1 to 9999)\z/,
            "$case->[1] is refused with a reason";
    }
    is versions_of('Malformed term'), 0, 'and no version is written';
};

subtest 'a price too small for every part to be a cent is refused' => sub {
    my $run = session_run( 'Penny term', days_from_now(7), days_from_now(70) );
    $run->update_data( $db, { offer_price => { price_cents => 1, currency => 'usd', units_per_acceptance => 1, per_booking_cap => 1 } } );
    my $why = 'A price of 1 cent cannot be split into 52 payments of at least a cent each';
    is errors_of( $run->process( $db, step('instalment-payment'), { instalments => 'offered', count => 52, cadence => 'weekly' } ) ),
        $why, 'the step refuses 52 parts of a 1 cent price';
    $run->update_data( $db, {
        instalment_payment    => { id => 'parts', count => 52, cadence => 'weekly', surcharge_pct => undef },
        missed_payment_policy => { kind => 'end' },
    } );
    is errors_of( $publish->process( $db, { action => 'publish' }, $run ) ), $why, 'and so does publish';
    is versions_of('Penny term'), 0, 'which writes no version';
};

done_testing;
