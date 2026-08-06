# ABOUTME: Proves the enrollment payment step works inside a running Mojo::IOLoop,
# ABOUTME: the production condition under which a blocking ->wait is a silent no-op.
#
# Mojo::Promise::wait opens with `return if $self->ioloop->is_running`. Both
# Mojo::Promise and Mojo::Server::Daemon default that ioloop to
# Mojo::IOLoop->singleton, so under `./registry daemon` a blocking wait never
# settles. Every test that drives this step through `prove` alone runs with no
# loop running and therefore cannot see the failure -- these subtests start the
# loop first, the way a real web request does.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;

use Mojo::IOLoop;
use Mojo::Promise;

use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Family;
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Location;
use Registry::DAO::Payment;
use Registry::DAO::WorkflowSteps::Payment;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::Service::Stripe;
use Test::Registry::DB;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $slug = 'async_step_' . $$;

my $admin = Registry::DAO::User->create($db, {
    username  => "async_admin_$$",
    email     => "async_admin_$$\@test.example",
    name      => 'Async Admin',
    user_type => 'admin',
});

my $tenant = Registry::DAO::Tenant->provision($db, {
    name  => "Async Tenant $$",
    slug  => $slug,
    users => [$admin],
});
ok $tenant, 'tenant provisioned';

# Paid enrollment is gated on Connect readiness; make the tenant ready.
$db->query(
    'UPDATE registry.tenants
        SET stripe_connect_account_id = $1,
            stripe_charges_enabled    = TRUE,
            stripe_details_submitted  = TRUE
      WHERE slug = $2',
    'acct_async_test', $slug,
);

my $tdao = Registry::DAO->new( url => $test_db->uri, schema => $slug );
my $tdb  = $tdao->db;

my $location = Registry::DAO::Location->create($tdb, {
    name         => 'Async Studio',
    address_info => { street_address => '1 Async Way', city => 'T', state => 'TX', postal_code => '78701' },
    metadata     => {},
});

my $teacher = Registry::DAO::User->create($tdb, {
    name      => 'Async Teacher',
    username  => "async_teacher_$$",
    email     => "async_teacher_$$\@test.com",
    user_type => 'staff',
});

my $project = Registry::DAO::Project->create($tdb, {
    name              => 'Async Camp',
    slug              => "async_camp_$$",
    status            => 'published',
    program_type_slug => 'summer-camp',
    metadata          => {},
});

my $event = Registry::DAO::Event->create($tdb, {
    time        => '2026-07-01 10:00:00',
    duration    => 120,
    location_id => $location->id,
    project_id  => $project->id,
    teacher_id  => $teacher->id,
    capacity    => 20,
    metadata    => {},
});

my $session = Registry::DAO::Session->create($tdb, {
    name       => 'Async Week',
    start_date => '2026-07-01',
    end_date   => '2026-07-07',
    status     => 'published',
    capacity   => 20,
    metadata   => {},
});
$session->add_events( $tdb, $event->id );

my $PLAN_AMOUNT_CENTS = 15_000;
Registry::DAO::PricingPlan->create($tdb, {
    session_id => $session->id,
    plan_name  => 'Standard',
    plan_type  => 'standard',
    amount_cents => $PLAN_AMOUNT_CENTS,
});

my $parent = Registry::DAO::User->create($tdb, {
    email     => "async_parent_$$\@example.com",
    username  => "async_parent_$$",
    name      => 'Async Parent',
    user_type => 'parent',
});

my $child = Registry::DAO::Family->add_child($tdb, $parent->id, {
    child_name        => 'Async Child',
    birth_date        => '2018-03-15',
    grade             => '3',
    medical_info      => {},
    emergency_contact => { name => 'Emergency', phone => '555-0199' },
});

my $workflow = Registry::DAO::Workflow->create($tdb, {
    name        => 'Async Test Workflow',
    slug        => "async-workflow-$$",
    description => 'Async payment step test workflow',
});

my $payment_step_row = Registry::DAO::WorkflowStep->create($tdb, {
    workflow_id => $workflow->id,
    slug        => 'payment',
    class       => 'Registry::DAO::WorkflowSteps::Payment',
    description => 'Payment processing step',
});

Registry::DAO::WorkflowStep->create($tdb, {
    workflow_id => $workflow->id,
    slug        => 'complete',
    class       => 'Registry::DAO::WorkflowStep',
    description => 'Completion step',
    depends_on  => $payment_step_row->id,
});

$workflow->update( $tdb, { first_step => 'payment' }, { id => $workflow->id } );

sub make_run {
    my $run = $workflow->new_run($tdb);
    $run->update_data($tdb, {
        user_id  => $parent->id,
        children => [ {
            id         => $child->id,
            first_name => 'Async',
            last_name  => 'Child',
            birth_date => '2018-03-15',
            grade      => '3',
        } ],
        session_selections => { $child->id => $session->id },
        enrollment_items   => [ { child_id => $child->id, session_id => $session->id } ],
        __tenant_slug      => $slug,
    });
    return $run;
}

sub payment_step { $workflow->get_step( $tdb, { slug => 'payment' } ) }

# Run $code inside a started IOLoop and return ($resolved, $error).
#
# The point of the whole file: the callback body executes with the singleton
# loop already running, exactly as a Mojolicious request handler does. A step
# that blocks on ->wait cannot settle here.
sub in_running_loop ($code) {
    my ( $resolved, $error, $not_a_promise );

    Mojo::IOLoop->next_tick(sub {
        my $p = eval { $code->() };
        if ($@) { $error = $@; Mojo::IOLoop->stop; return }

        unless ( ref $p && $p isa Mojo::Promise ) {
            $not_a_promise = $p // '(undef)';
            Mojo::IOLoop->stop;
            return;
        }

        $p->then( sub { $resolved = shift } )
          ->catch( sub { $error = shift } )
          ->finally( sub { Mojo::IOLoop->stop } );
    });

    # Safety net: without this a step that never settles hangs the suite
    # forever instead of failing.
    my $guard = Mojo::IOLoop->timer( 10 => sub {
        $error //= 'timed out waiting for the step to settle';
        Mojo::IOLoop->stop;
    });

    Mojo::IOLoop->start;
    Mojo::IOLoop->remove($guard);

    $error //= "step returned a non-promise ($not_a_promise) instead of deferring"
        if defined $not_a_promise;

    return ( $resolved, $error );
}

# A Stripe stub that resolves on a LATER tick, the way a real HTTP round trip
# does. Resolving immediately would mask exactly the bug under test.
sub deferred ($value) {
    my $p = Mojo::Promise->new;
    Mojo::IOLoop->next_tick( sub { $p->resolve($value) } );
    return $p;
}

subtest 'create_payment settles inside a running IOLoop' => sub {
    my $run = make_run();

    no warnings 'redefine';
    local *Registry::Service::Stripe::create_payment_intent_async = sub {
        return deferred({ id => 'pi_async_1', client_secret => 'cs_async_1' });
    };

    my ( $result, $error ) = in_running_loop(
        sub { payment_step()->process( $tdb, { agreeTerms => 1 }, $run ) } );

    is $error, undef, 'step settled without dying inside the running loop'
        or diag "error: $error";
    # Nested under step_data because that is the key the template reads; the
    # controller splats a step's rendering data flat into the stash, so
    # anything returned unwrapped never reaches the page.
    is $result->{data}{step_data}{client_secret}, 'cs_async_1',
        'client_secret from the deferred Stripe response reaches the caller';
    ok $result->{data}{step_data}{show_stripe_form}, 'stripe form flagged for display';
};

subtest 'handle_payment_callback settles inside a running IOLoop' => sub {
    my $run = make_run();

    my $payment = Registry::DAO::Payment->create($tdb, {
        user_id  => $parent->id,
        amount_cents => $PLAN_AMOUNT_CENTS,
        metadata => {
            tenant_slug      => $slug,
            enrollment_items => [ { child_id => $child->id, session_id => $session->id } ],
        },
    });
    $payment->update( $tdb, { stripe_payment_intent_id => 'pi_cb_ok' } );
    $run->update_data( $tdb, { payment_id => $payment->id } );

    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent_async = sub {
        return deferred({
            id             => 'pi_cb_ok',
            status         => 'succeeded',
            amount         => $PLAN_AMOUNT_CENTS,
            payment_method => 'pm_async_1',
            metadata       => { payment_id => $payment->id },
        });
    };

    my ( $result, $error ) = in_running_loop(
        sub { payment_step()->process( $tdb, { payment_intent_id => 'pi_cb_ok' }, $run ) } );

    is $error, undef, 'callback settled without dying inside the running loop'
        or diag "error: $error";
    is $result->{next_step}, 'complete', 'successful payment advances to complete';
};

# The async path historically had no intent-ownership check while the sync path
# did. Moving the enrollment path onto promises must not drop that guard: an
# intent belonging to some other payment row must never settle this one.
subtest 'intent-ownership guard survives on the async path' => sub {
    my $run = make_run();

    my $payment = Registry::DAO::Payment->create($tdb, {
        user_id  => $parent->id,
        amount_cents => $PLAN_AMOUNT_CENTS,
        metadata => {
            tenant_slug      => $slug,
            enrollment_items => [ { child_id => $child->id, session_id => $session->id } ],
        },
    });
    $payment->update( $tdb, { stripe_payment_intent_id => 'pi_mine' } );
    $run->update_data( $tdb, { payment_id => $payment->id } );

    no warnings 'redefine';
    # A genuinely succeeded intent that belongs to somebody else's payment row.
    local *Registry::Service::Stripe::retrieve_payment_intent_async = sub {
        return deferred({
            id       => 'pi_someone_else',
            status   => 'succeeded',
            amount   => $PLAN_AMOUNT_CENTS,
            metadata => { payment_id => '00000000-0000-0000-0000-0000000000ff' },
        });
    };

    my ( $result, $error ) = in_running_loop(
        sub { payment_step()->process( $tdb, { payment_intent_id => 'pi_someone_else' }, $run ) } );

    is $error, undef, 'settled without dying' or diag "error: $error";
    isnt $result->{next_step}, 'complete',
        'a foreign intent does not complete this enrollment';

    my $reloaded = Registry::DAO::Payment->find( $tdb, { id => $payment->id } );
    isnt $reloaded->status, 'completed',
        'payment row is not marked completed by a foreign intent';
};

# The back button, not an attacker: a 3DS attempt fails, Stripe redirects back,
# the decline branch cancels pi_first and mints pi_second, the parent pays with
# pi_second -- and then goes back one page, re-firing the finalizer on the
# pi_first history entry. The DAO refuses to demote the row; the step must not
# leave the parent staring at an error for a payment that went through.
subtest 'a stale intent still routes a paid parent to completion' => sub {
    my $run = make_run();

    # Its own child: enrollments are unique per (session, student), and this
    # subtest actually settles a payment rather than stopping at the guard.
    my $sibling = Registry::DAO::Family->add_child($tdb, $parent->id, {
        child_name        => 'Async Sibling',
        birth_date        => '2019-05-20',
        grade             => '2',
        medical_info      => {},
        emergency_contact => { name => 'Emergency', phone => '555-0199' },
    });

    my $payment = Registry::DAO::Payment->create($tdb, {
        user_id  => $parent->id,
        amount_cents => $PLAN_AMOUNT_CENTS,
        metadata => {
            tenant_slug      => $slug,
            enrollment_items => [ { child_id => $sibling->id, session_id => $session->id } ],
        },
    });
    $payment->update( $tdb, { stripe_payment_intent_id => 'pi_second' } );
    $run->update_data( $tdb, { payment_id => $payment->id } );

    no warnings 'redefine';

    # The payment the parent actually made.
    {
        local *Registry::Service::Stripe::retrieve_payment_intent_async = sub {
            return deferred({
                id             => 'pi_second',
                status         => 'succeeded',
                amount         => $PLAN_AMOUNT_CENTS,
                payment_method => 'pm_async_2',
                metadata       => { payment_id => $payment->id },
            });
        };

        my ( $settled, $err ) = in_running_loop(
            sub { payment_step()->process( $tdb, { payment_intent_id => 'pi_second' }, $run ) } );
        is $err, undef, 'setup: pi_second settled' or diag "error: $err";
        is $settled->{next_step}, 'complete', 'setup: pi_second completed the enrollment';
    }

    # The superseded intent the browser still holds. It carries our payment_id,
    # like every intent minted for this row, so ownership alone lets it through.
    local *Registry::Service::Stripe::retrieve_payment_intent_async = sub {
        return deferred({
            id       => 'pi_first',
            status   => 'canceled',
            metadata => { payment_id => $payment->id },
        });
    };

    my ( $result, $error ) = in_running_loop(
        sub { payment_step()->process( $tdb, { payment_intent_id => 'pi_first' }, $run ) } );

    is $error, undef, 'settled without dying' or diag "error: $error";
    is $result->{next_step}, 'complete',
        'a parent who already paid lands on completion, not an error page';
    ok !$result->{errors}, 'no error is shown for a payment that succeeded';
    ok !$result->{data}{step_data}{show_stripe_form},
        'no live card form is offered to a parent who already paid';

    my $reloaded = Registry::DAO::Payment->find( $tdb, { id => $payment->id } );
    is $reloaded->status, 'completed', 'payment is still completed';
    is $reloaded->stripe_payment_intent_id, 'pi_second',
        'the capturing intent is still the one on record';
};

done_testing();
