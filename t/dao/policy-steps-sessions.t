#!/usr/bin/env perl
# ABOUTME: The refund, change and use policy steps ask for approval, change targets, price difference and make-ups.
# ABOUTME: Each choice is saved and published; in-studio publishes keep approval none; make-up and target offers must be this tenant's.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( import_all_workflows join_tenant publish_offer );
use Registry::DAO;
use Registry::DAO::OfferVersion;
use Registry::DAO::WorkflowSteps::ChooseOfferAndUnits;
use Registry::Utility::WorkflowProcessor;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
import_all_workflows($dao);

my $admin = Test::Registry::Fixtures::create_user( $dao,
    { username => 'policy_admin', name => 'Policy Admin', email => 'admin@policy.test', user_type => 'admin' } );

# Two studios, each with a class and a current offer covering it.
my %studio;
for my $slug (qw( dance_studio pottery_studio )) {
    Test::Registry::Fixtures::create_tenant( $dao, { name => "\u$slug", slug => $slug } );
    my $tdao = $dao->connect_schema($slug);
    import_all_workflows($tdao);
    join_tenant( $dao, $admin, 'admin', $slug );
    my $class = Test::Registry::Fixtures::create_project( $tdao->db, { name => "$slug class", slug => "$slug-class", seats_per_occurrence => 8 } );
    my $makeup = publish_offer( $dao, $slug, $admin, {
        resource        => { resource_mode => 'class', class_project_id => $class->id },
        'offer-basics'  => { offer_name => "$slug make-up" },
        'offer-price'   => { price_cents => 2000, currency => 'usd', units_per_acceptance => 1, per_booking_cap => 1 },
        'expiry-policy' => { expiry => 'end_of_occurrence' },
    } );
    $studio{$slug} = { dao => $tdao, db => $tdao->db, class => $class, makeup_offer_id => $makeup->offer_id };
}
my ( $tdao, $tdb, $class ) = $studio{dance_studio}->@{qw( dao db class )};
my $unknown = '6f1c1f0e-3b7a-4d6e-9a51-2f0d8c4b7e13';

# Walks $slug's stored steps as the admin on a class offer, submitting
# %override's fields over valid answers for each step; a slug mapped to undef
# is never submitted. Returns the run and each step's result by slug.
sub walk ( $slug, %override ) {
    my %fields = (
        'resource'         => { resource_mode => 'class', class_project_id => $class->id },
        'class'            => { class_mode => 'existing', class_project_id => $class->id },
        'offer-basics'     => { offer_name => 'Ballet ' . ++( state $n ) },
        'offer-price'      => { price_cents => 9000, currency => 'usd', units_per_acceptance => 1, per_booking_cap => 1 },
        'one-time-payment' => { one_time => 'offered' },
        'percentage-of-sales-payment' => { percentage_of_sales => 'declined' },
        'refund-policy'    => { refund => 'none' },
        'change-policy'    => { change => 'none' },
        'use-policy'       => { use => 'none' },
        'expiry-policy'    => { expiry => 'end_of_occurrence' },
        'publish'          => { action => 'publish' },
    );
    my $workflow = $tdao->find( Workflow => { slug => $slug } );
    my $run = Registry::WorkflowProcessor->new( dao => $tdao )
        ->new_run( $workflow, { user => { id => $admin->id, name => $admin->name } } );
    my %result;
    for ( my $step = $workflow->first_step($tdb) ; $step ; $step = $step->next_step($tdb) ) {
        my $s = $step->slug;
        next if $s eq 'complete' || ( exists $override{$s} && !defined $override{$s} );
        $result{$s} = $run->process( $tdb, $step, { ( $fields{$s} // {} )->%*, ( $override{$s} // {} )->%* } );
    }
    return ( $run, \%result );
}

sub published ($run) {
    my $id = $run->data->{published_offer_version_id} or return;
    return Registry::DAO::OfferVersion->find( $tdb, { id => $id } );
}

sub errors_of ($result) { join ' ', ( ( ref $result eq 'HASH' ? $result->{errors} : undef ) // [] )->@* }

my %WINDOW = ( change => 'window', window_hours => 48, fee_cents => 1000 );
my %version;

subtest 'the refund policy step saves approval' => sub {
    my ( $run, $result ) = walk( 'offer-publishing', 'refund-policy' => { refund => 'none', approval => 'required' } );
    is errors_of( $result->{'refund-policy'} ), '', 'the step accepts approval required';
    is_deeply $run->data->{refund_policy}, { kind => 'none', approval => 'required' }, 'and saves it';
    my $version = published($run) or return fail 'publish: ' . errors_of( $result->{publish} );
    is_deeply $version->policies->{refund}, { kind => 'none', approval => 'required' }, 'which is published';
    $version{refund} = $version;

    ( $run, $result ) = walk('offer-publishing');
    is_deeply $run->data->{refund_policy}, { kind => 'none', approval => 'none' }, 'an unanswered approval is saved as none';
};

subtest 'the change policy step saves targets, price difference and approval' => sub {
    my ($mine) = $studio{dance_studio}{makeup_offer_id};
    for my $case (
        [ { targets => 'same_program', price_difference => 'charge_and_refund', approval => 'required' },
          { targets => 'same_program', price_difference => 'charge_and_refund', approval => 'required' } ],
        [ { targets => 'offer_ids', offer_ids => [$mine], price_difference => 'charge_only', approval => 'none' },
          { targets => { offer_ids => [$mine] }, price_difference => 'charge_only', approval => 'none' } ],
        [ { targets => 'same_program' },
          { targets => 'same_program', price_difference => 'same_price_only', approval => 'none' } ],
    ) {
        my ( $form, $saved ) = @$case;
        my ( $run, $result ) = walk( 'offer-publishing', 'change-policy' => { %WINDOW, %$form } );
        is errors_of( $result->{'change-policy'} ), '', "the step accepts targets $form->{targets}";
        my %want = ( kind => 'window', window_hours => 48, fee_cents => 1000, %$saved );
        is_deeply $run->data->{change_policy}, \%want, 'and saves targets, price difference and approval';
        my $version = published($run) or return fail 'publish: ' . errors_of( $result->{publish} );
        is_deeply $version->policies->{change}, \%want, 'which are published';
        $version{"change_$saved->{price_difference}"} = $version;
    }
};

subtest 'the use policy step saves a makeup offer' => sub {
    my $offer_id = $studio{dance_studio}{makeup_offer_id};
    my ( $run, $result ) = walk( 'offer-publishing',
        'use-policy' => { use => 'makeup', makeup_offer_id => $offer_id, credit_days => 30, max_per_term => 4 } );
    is errors_of( $result->{'use-policy'} ), '', 'the step accepts a make-up offer';
    is_deeply $run->data->{use_policy}, { use => 'makeup', offer_id => $offer_id, credit_days => 30, max_per_term => 4 },
        'and saves it';
    my $version = published($run) or return fail 'publish: ' . errors_of( $result->{publish} );
    is_deeply $version->policies->{use}, { kind => 'makeup', offer_id => $offer_id, credit_days => 30, max_per_term => 4 },
        'which is published';
    $version{makeup} = $version;

    ( $run, $result ) = walk( 'offer-publishing',
        'use-policy' => { use => 'makeup', makeup_offer_id => $offer_id, credit_days => 14, max_per_term => '' } );
    is_deeply published($run) && published($run)->policies->{use},
        { kind => 'makeup', offer_id => $offer_id, credit_days => 14 }, 'max_per_term is optional';
};

subtest 'an in-studio publish still writes approval none' => sub {
    my ( $run, $result ) = walk( 'in-studio-class-setup',
        'refund-policy' => { refund => 'none', approval => 'required' },
        'change-policy' => { %WINDOW, targets => 'same_program', price_difference => 'charge_and_refund', approval => 'required' } );
    my $version = published($run) or return fail 'publish: ' . join ' ', map { errors_of($_) } values %$result;
    is_deeply $version->policies->{refund}, { kind => 'none', approval => 'none' }, 'refunds need no approval';
    is_deeply $version->policies->{change},
        { kind => 'window', window_hours => 48, fee_cents => 1000, targets => 'same_offer',
          price_difference => 'same_price_only', approval => 'none' },
        'changes need no approval and stay within the offer at the same price';
    $version{in_studio} = $version;
};

subtest 'policy words describe approval, price difference and make-ups' => sub {
    my $words = sub ($key) { join ' ', Registry::DAO::WorkflowSteps::ChooseOfferAndUnits->policy_words( $version{$key} )->@* };
    like $words->('refund'), qr/\QRefunds are reviewed by the studio before they are made.\E/, 'refund approval';
    like $words->('change_charge_and_refund'), qr/\QChanges are reviewed by the studio.\E/, 'change approval';
    like $words->('change_charge_and_refund'), qr/\QMoving to a different price charges or refunds the difference.\E/,
        'charge and refund';
    like $words->('change_charge_only'), qr/\QMoving to a different price charges the difference.\E/, 'charge only';
    unlike $words->('change_charge_only'), qr/reviewed/, 'no approval, no review';
    like $words->('change_same_price_only'), qr/\QMoving is allowed only to the same price.\E/, 'same price only';
    like $words->('makeup'), qr/\QA missed day earns a make-up class within 30 days.\E/, 'make-ups';
    unlike $words->('in_studio'), qr/reviewed|Moving/, 'an in-studio window says nothing of review or price';
};

subtest 'a makeup naming another tenant offer is refused' => sub {
    my ( $run, $result ) = walk( 'offer-publishing', 'use-policy' => { use => 'makeup',
        makeup_offer_id => $studio{pottery_studio}{makeup_offer_id}, credit_days => 30 } );
    is errors_of( $result->{'use-policy'} ), 'Choose one of your current class offers for make-ups', 'the step refuses it';
    ok !published($run), 'and nothing is published';

    $run->update_data( $tdb, { use_policy => { use => 'makeup', offer_id => $studio{pottery_studio}{makeup_offer_id}, credit_days => 30 } } );
    my $publish = $tdao->find( Workflow => { slug => 'offer-publishing' } )->get_step( $tdb, { slug => 'publish' } );
    is errors_of( $publish->process( $tdb, { action => 'publish' }, $run ) ),
        'Choose one of your current class offers for make-ups', 'and so does publish';
};

subtest 'a makeup naming an unknown offer is refused' => sub {
    my ( $run, $result ) = walk( 'offer-publishing',
        'use-policy' => { use => 'makeup', makeup_offer_id => $unknown, credit_days => 30 } );
    is errors_of( $result->{'use-policy'} ), 'Choose one of your current class offers for make-ups', 'the step refuses it';
    ok !published($run), 'and nothing is published';
};

subtest 'offer_ids naming an unknown offer is refused' => sub {
    my ( $run, $result ) = walk( 'offer-publishing',
        'change-policy' => { %WINDOW, targets => 'offer_ids', offer_ids => [ $studio{dance_studio}{makeup_offer_id}, $unknown ] } );
    is errors_of( $result->{'change-policy'} ), 'Choose the offers a change may move to from your offers',
        'the step refuses it';
    ok !published($run), 'and nothing is published';

    $run->update_data( $tdb, { change_policy => { kind => 'window', window_hours => 48, fee_cents => 1000,
        targets => { offer_ids => [$unknown] }, price_difference => 'charge_only', approval => 'none' } } );
    my $publish = $tdao->find( Workflow => { slug => 'offer-publishing' } )->get_step( $tdb, { slug => 'publish' } );
    is errors_of( $publish->process( $tdb, { action => 'publish' }, $run ) ),
        'Choose the offers a change may move to from your offers', 'and so does publish';
};

done_testing;
