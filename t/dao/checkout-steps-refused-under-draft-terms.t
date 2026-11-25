# ABOUTME: In production, while /terms is the DRAFT placeholder, each checkout step refuses before any write.
# ABOUTME: OneTimePayment, PayChangeFee and the enrollment Payment step: no payment row, no hold extended, no intent.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::PricingProbe qw( give_tenant_terms );
use Test::Registry::Offers qw( offer_terms );
use Mojo::Promise;
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::DAO::Offer;
use Registry::DAO::Resource;
use Registry::DAO::Entitlement;
use Registry::DAO::Family;
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Location;
use Registry::PriceOps::Hold;
use Registry::Terms;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $slug  = "draft_steps_$$";
my $admin = Registry::DAO::User->create( $db, {
    username => "ds_admin_$$", email => "ds_admin_$$\@test.example", name => 'DS Admin', user_type => 'admin' } );
Registry::DAO::Tenant->provision( $db, {
    name => "Draft Steps $$", slug => $slug, users => [$admin],
    stripe_connect_account_id => "acct_ds_$$", stripe_charges_enabled => 1, stripe_details_submitted => 1 } );
give_tenant_terms( $db, $slug, { rate => '0.025' } );
my $tdb = Registry::DAO->new( url => $test_db->uri, schema => $slug )->db;

my $seats   = Registry::DAO::Resource->create( $tdb, { name => 'Wheel seats', kind => 'finite', capacity => 10 } );
my $version = Registry::DAO::Offer->create( $tdb, { name => 'Wheel class' } )
    ->draft( $tdb, offer_terms( $seats->id ) )->publish($tdb);
my $buyer = Registry::DAO::User->create( $tdb, {
    username => "ds_buyer_$$", email => "ds_buyer_$$\@test.example", name => 'DS Buyer', user_type => 'parent' } );

my $REFUSAL = do { local $ENV{MOJO_MODE} = 'production'; Registry::Terms::checkout_refusal() };
ok $REFUSAL, 'production has a refusal while the terms are the placeholder';

sub payments ($handle) { $handle->query('SELECT count(*) FROM payments')->array->[0] }

# A workflow before -> pay -> after, pay being $class, and a run parked on pay
# owing for a live hold of one seat.
my $made = 0;
sub owing_run ( $class, %data ) {
    $made++;
    my $wf = Registry::DAO::Workflow->create( $tdb, {
        name => "DS $made", slug => "ds-$made-$$", description => 'draft terms checkout' } );
    $wf->add_step( $tdb, { slug => $_->[0], class => $_->[1] } ) for
        [ before => 'Registry::DAO::WorkflowStep' ], [ pay => $class ], [ after => 'Registry::DAO::WorkflowStep' ];
    my $run = $wf->new_run( $tdb, {} );
    $run->process( $tdb, $wf->first_step($tdb), {} );
    my $hold = Registry::PriceOps::Hold->place( $tdb, {
        resource_id => $seats->id, units => 1, workflow_run_id => $run->id,
        expires_at  => \"now() + interval '15 minutes'" } );
    $run->update_data( $tdb, {
        user_id       => $buyer->id,
        __tenant_slug => $slug,
        owed_payment  => {
            offer_version_id => $version->id, payment_plan => 'pay', amount_cents => 2500,
            description      => 'Wheel class', hold_id => $hold->id,
        },
        %data,
    } );
    return ( $wf, Registry::DAO::WorkflowRun->find( $tdb, { id => $run->id } ), $hold );
}

sub expires_at ($hold) { $tdb->query( 'SELECT expires_at FROM holds WHERE id = ?', $hold->id )->array->[0] }

sub refused_before_any_write ( $label, $step, $run, $form, $hold = undef ) {
    my $before_payments = payments($tdb);
    my $before_expiry   = $hold ? expires_at($hold) : undef;
    my $result = do { local $ENV{MOJO_MODE} = 'production'; $step->process( $tdb, $form, $run ) };
    ok !( $result isa Mojo::Promise ), "$label: refused without calling Stripe";
    is_deeply $result->{errors}, [$REFUSAL], "$label: the payer is told why" or diag explain $result;
    is payments($tdb), $before_payments, "$label: no payment row written";
    is expires_at($hold), $before_expiry, "$label: the hold's expiry is unchanged" if $hold;
    my $data = Registry::DAO::WorkflowRun->find( $tdb, { id => $run->id } )->data;
    ok !exists $data->{owed_payment_id} && !exists $data->{payment_id}, "$label: the run names no payment";
}

subtest 'one time payment refused before any write' => sub {
    my ( $wf, $run, $hold ) = owing_run('Registry::DAO::WorkflowSteps::OneTimePayment');
    refused_before_any_write( 'one-time', $wf->get_step( $tdb, { slug => 'pay' } ), $run, {}, $hold );
};

subtest 'change fee refused before any write' => sub {
    my $booking = Registry::DAO::Entitlement->grant( $tdb, {
        holder_user_id => $buyer->id, offer_version_id => $version->id, payment_plan_id => 'pay',
        starts_at      => '2020-01-01T00:00:00Z', resource_id => $seats->id, units => 1 } );
    my ( $wf, $run, $hold ) = owing_run( 'Registry::DAO::WorkflowSteps::PayChangeFee',
        user => { id => $buyer->id } );
    $run->update_data( $tdb, {
        change_hold => { entitlement_id => $booking->id, fee_cents => 2500, hold_id => $hold->id } } );
    $run = Registry::DAO::WorkflowRun->find( $tdb, { id => $run->id } );
    refused_before_any_write( 'change fee', $wf->get_step( $tdb, { slug => 'pay' } ), $run, {}, $hold );
};

subtest 'enrollment payment refused before any write' => sub {
    my $location = Registry::DAO::Location->create( $tdb, {
        name => 'DS Studio', metadata => {},
        address_info => { street_address => '1 Way', city => 'T', state => 'TX', postal_code => '78701' } } );
    my $teacher = Registry::DAO::User->create( $tdb, {
        name => 'DS Teacher', username => "ds_teacher_$$", email => "ds_teacher_$$\@test.example", user_type => 'staff' } );
    my $project = Registry::DAO::Project->create( $tdb, {
        name => 'DS Camp', slug => "ds_camp_$$", status => 'published', program_type_slug => 'summer-camp', metadata => {} } );
    my $event = Registry::DAO::Event->create( $tdb, {
        time => '2099-07-01 10:00:00', duration => 120, location_id => $location->id,
        project_id => $project->id, teacher_id => $teacher->id, capacity => 20, metadata => {} } );
    my $session = Registry::DAO::Session->create( $tdb, {
        name => 'DS Week', start_date => '2099-07-01', end_date => '2099-07-07',
        status => 'published', capacity => 20, metadata => {} } );
    $session->add_events( $tdb, $event->id );
    Registry::DAO::PricingPlan->create( $tdb, {
        session_id => $session->id, plan_name => 'Standard', plan_type => 'standard', amount_cents => 15_000 } );
    my $child = Registry::DAO::Family->add_child( $tdb, $buyer->id, {
        child_name => 'DS Child', birth_date => '2018-03-15', grade => '3',
        medical_info => {}, emergency_contact => { name => 'E', phone => '555-0199' } } );

    my ( $wf, $run ) = owing_run( 'Registry::DAO::WorkflowSteps::Payment',
        children           => [ { id => $child->id, first_name => 'DS', last_name => 'Child' } ],
        session_selections => { $child->id => $session->id },
        enrollment_items   => [ { child_id => $child->id, session_id => $session->id } ],
    );
    local $ENV{STRIPE_SECRET_KEY} = 'ci_placeholder_not_a_stripe_key';
    refused_before_any_write( 'enrollment', $wf->get_step( $tdb, { slug => 'pay' } ), $run, { agreeTerms => 1 } );
};

done_testing;
