#!/usr/bin/env perl
# ABOUTME: Proves a client cannot write the server-owned workflow run-data keys __tenant_slug and user_id.
# ABOUTME: __tenant_slug alone selects the seller Stripe account a charge is made on and the fee rate.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::SoloVersion qw( publish_solo_version accept_solo );
use Registry::PriceOps::PlatformTerms ();
use Test::Registry::Fixtures;
use Test::Registry::Mojo;
use Test::Registry::Helpers qw( authenticate_as start_run );

use Registry::DAO qw(Workflow);
use Registry::DAO::Workflow;
use Registry::DAO::Tenant;
use Registry::DAO::Resource;
use Registry::DAO::WorkflowStep;
use Registry::DAO::WorkflowRun;
use Registry::DAO::User;
use Registry::DAO::Family;
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;
use Registry::DAO::Payment;
use Registry::DAO::WorkflowSteps::Payment;
use Registry::Service::Stripe;
use Mojo::Promise;
use Test::Registry::Async qw( settle );

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# A real tenant schema so the tenant helper resolves <slug>.localhost instead of
# degrading to the platform.
Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Host Tenant',
    slug => 'hosttenant',
});
$dao->db->query('SELECT clone_schema(?)', 'hosttenant');

# Two passthrough steps: no outcome definition, so validate() is a no-op and
# whatever the client posts is merged into the run's data.
my $workflow = Registry::DAO::Workflow->create($dao->db, {
    name        => 'Run Data Test Workflow',
    slug        => 'run-data-test',
    description => 'Landing passthrough followed by a completion step',
    public      => 1,    # the gate refuses a workflow with no entry
});
my $landing = Registry::DAO::WorkflowStep->create($dao->db, {
    workflow_id => $workflow->id,
    slug        => 'landing',
    class       => 'Registry::DAO::WorkflowStep',
    description => 'Landing',
});
Registry::DAO::WorkflowStep->create($dao->db, {
    workflow_id => $workflow->id,
    slug        => 'complete',
    class       => 'Registry::DAO::WorkflowStep',
    description => 'Complete',
    depends_on  => $landing->id,
});
$workflow->update($dao->db, { first_step => 'landing' }, { id => $workflow->id });

# hosttenant runs run-data-test, which only this test's registry has: it
# accepts a Solo version whose set also lists that workflow's run right, at 0%.
my $solo_now = publish_solo_version( $dao->db, 0,
    Registry::DAO::Resource->find( $dao->db, { name => 'run:run-data-test' } )->id );
accept_solo( $dao->db, Registry::DAO::Tenant->find( $dao->db, { slug => 'hosttenant' } ) );
subtest 'platform terms are stated' => sub {
    cmp_ok Registry::PriceOps::PlatformTerms::platform_terms_for_tenant( $dao->db, 'hosttenant' )->{fraction},
        '==', 0, 'hosttenant is charged at the stated rate';
};

my $session_user = Registry::DAO::User->create($dao->db, {
    name      => 'Logged In Parent',
    username  => 'loggedin',
    email     => 'loggedin@example.com',
    user_type => 'parent',
});
my $other_user = Registry::DAO::User->create($dao->db, {
    name      => 'Someone Else',
    username  => 'someoneelse',
    email     => 'someoneelse@example.com',
    user_type => 'parent',
});

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

# Every run here is started through the app, as its owner would start it, which
# takes this one client past the per-IP limit of a minute's browsing.
use Registry::Middleware::RateLimit;
$Registry::Middleware::RateLimit::GENERAL_LIMIT = $Registry::Middleware::RateLimit::AUTH_LIMIT = 10_000;

# A run past the landing step, ready for a POST to the next one. Started
# through the app, so it belongs to $t's session (or signed-in user).
sub run_on_second_step {
    return start_run( $t, $dao->db, $workflow );
}

sub data_for {
    my ($run_id) = @_;
    my ($fresh) = $dao->find(WorkflowRun => { id => $run_id });
    return $fresh->data;
}

subtest 'run creation ignores posted server-owned keys' => sub {
    $t->post_ok('/run-data-test' => form => {
        __tenant_slug => 'victim_tenant',
        user_id       => $other_user->id,
    })->status_is(302);

    my ($run_id) = $t->tx->res->headers->location =~ m{/run-data-test/([^/]+)/};
    my $data = data_for($run_id);

    # The bare host resolves to the platform tenant, which sells like any other.
    is $data->{__tenant_slug}, 'registry',
        'the stored __tenant_slug is the platform, not the posted victim_tenant';
    ok !exists $data->{user_id},
        'posted user_id is not stored at run creation';
};

subtest 'a later step cannot plant them either' => sub {
    my $run = run_on_second_step();

    $t->post_ok("/run-data-test/${\ $run->id}/complete" => form => {
        __tenant_slug => 'victim_tenant',
        user_id       => $other_user->id,
    })->status_is(201);

    my $data = data_for($run->id);
    is $data->{__tenant_slug}, 'registry',
        'the stored __tenant_slug is the platform, not the posted victim_tenant';
    ok !exists $data->{user_id},
        'posted user_id is not stored on a subsequent step';
};

subtest 'a run on the platform tenant carries the registry seller slug' => sub {
    $t->post_ok('/run-data-test' => form => {})->status_is(302);

    my ($run_id) = $t->tx->res->headers->location =~ m{/run-data-test/([^/]+)/};
    is data_for($run_id)->{__tenant_slug}, 'registry',
        'the shared payment step can find the platform as the seller';
};

subtest 'on a tenant host a later step gets the host tenant, not the posted one' => sub {
    my $run = run_on_second_step();

    $t->post_ok("/run-data-test/${\ $run->id}/complete"
        => { Host => 'hosttenant.localhost' }
        => form => { __tenant_slug => 'victim_tenant' }
    )->status_is(201);

    is data_for($run->id)->{__tenant_slug}, 'hosttenant',
        'run data carries the tenant the request actually arrived at';
};

subtest 'posting registry as the seller on a tenant host stores the host tenant' => sub {
    $t->post_ok('/run-data-test'
        => { Host => 'hosttenant.localhost' }
        => form => { __tenant_slug => 'registry' }
    )->status_is(302);

    my ($run_id) = $t->tx->res->headers->location =~ m{/run-data-test/([^/]+)/};
    is data_for($run_id)->{__tenant_slug}, 'hosttenant',
        "a tenant's run cannot be made to sell as the platform";
};

subtest 'a posted seller slug on a later step does not change the stored seller' => sub {
    my $run = run_on_second_step();
    $run->update_data( $dao->db, { __tenant_slug => 'registry' } );

    $t->post_ok("/run-data-test/${\ $run->id}/complete"
        => form => { __tenant_slug => 'hosttenant' }
    )->status_is(201);

    is data_for($run->id)->{__tenant_slug}, 'registry',
        'the stored seller is still the platform, not the posted hosttenant';
};

subtest 'a bracketed variant cannot smuggle a structure into a server-owned key' => sub {
    my $run = run_on_second_step();

    # _apply_server_owned_data vets the FLAT param hash and touches only the
    # exact keys. expand_form_params runs afterwards, inside WorkflowStep, and
    # its bracket branch does `$ref->{$p} = {} unless ref $ref->{$p} eq 'HASH'`
    # -- destroying whatever scalar the server just put there and replacing it
    # with client-built structure. The scalar form of this attack is refused
    # above; the bracketed form went straight through.
    #
    # A structure here is not merely a wrong value. These keys are fed to
    # SQL::Abstract as WHERE values, where a hashref becomes an OPERATOR:
    # family_id => { '!=' => ... } renders `family_id != ?` and matches every
    # other family in the tenant.
    $t->post_ok("/run-data-test/${\ $run->id}/complete" => form => {
        'user_id[!=]'       => $other_user->id,
        '__tenant_slug[!=]' => 'victim_tenant',
    })->status_is(201);

    my $data = data_for($run->id);
    ok !ref $data->{user_id},
        'user_id is not a client-built structure';
    ok !ref $data->{__tenant_slug},
        '__tenant_slug is not a client-built structure';
};

subtest 'selected_offer_version cannot be planted by a client' => sub {
    my $run = run_on_second_step();

    # Same shape as the user_id bracket bypass above, on a different key. Only
    # signup's review step may write this, after checking the posted version
    # is a current published platform offer to tenants; provisioning grants
    # the version it names, so a planted one picks the terms the tenant gets.
    $t->post_ok("/run-data-test/${\ $run->id}/complete" => form => {
        'selected_offer_version[id]' => '00000000-0000-0000-0003-000000000002',
    })->status_is(201);

    ok !exists data_for($run->id)->{selected_offer_version},
        'a posted selected_offer_version is not stored';

    # The flat form too. The strip matches (?:\[|\z), and the \z branch is
    # load-bearing only for this key -- user_id and __tenant_slug are re-derived
    # immediately below it, so a bare posted value would be overwritten anyway.
    $run = run_on_second_step();
    $t->post_ok("/run-data-test/${\ $run->id}/complete" => form => {
        selected_offer_version => '00000000-0000-0000-0003-000000000002',
    })->status_is(201);

    ok !exists data_for($run->id)->{selected_offer_version},
        'a posted selected_offer_version is not stored';
};

subtest 'a change and its targets cannot be planted by a client' => sub {
    # The change steps write these; the fee charge reads change_hold.fee_cents as
    # the amount owed, so a planted one would set its own price.
    # change_needs_admin marks a paid change an admin must settle; a planted one hides it.
    for my $key (qw( change_hold change_entitlement_id change_targets change_needs_admin )) {
        my $run = run_on_second_step();
        $t->post_ok("/run-data-test/${\ $run->id}/complete" => form => {
            "${key}[fee_cents]" => 0,
            "${key}[hold_id]"   => '00000000-0000-0000-0000-000000000099',
        })->status_is(201);
        ok !exists data_for($run->id)->{$key}, "a bracketed posted $key is not stored";

        $run = run_on_second_step();
        $t->post_ok("/run-data-test/${\ $run->id}/complete" => form => { $key => 'planted' })->status_is(201);
        ok !exists data_for($run->id)->{$key}, "a flat posted $key is not stored";
    }
};

subtest 'a booking hold cannot be planted by a client' => sub {
    # HoldSeats writes booking_hold with the hold it placed; completing the
    # booking converts the hold it names, so a planted one picks the seats.
    for my $form ( { booking_hold => 'planted' },
                   { 'booking_hold[hold_id]' => '00000000-0000-0000-0000-000000000099' } ) {
        my $run = run_on_second_step();
        $t->post_ok("/run-data-test/${\ $run->id}/complete" => form => $form)->status_is(201);
        ok !exists data_for($run->id)->{booking_hold}, 'a posted booking_hold is not stored';
    }
};

subtest 'a refund target cannot be planted by a client' => sub {
    # refund_entitlement_id names the booking ApplyRefundPolicy refunds; only
    # the refund chooser writes it, once the booking is the asker's.
    for my $form ( { refund_entitlement_id => '00000000-0000-0000-0000-000000000099' },
                   { 'refund_entitlement_id[id]' => '00000000-0000-0000-0000-000000000099' } ) {
        my $run = run_on_second_step();
        $t->post_ok("/run-data-test/${\ $run->id}/complete" => form => $form)->status_is(201);
        ok !exists data_for($run->id)->{refund_entitlement_id}, 'a posted refund_entitlement_id is not stored';
    }
};

subtest 'an agreed terms version cannot be planted by a client' => sub {
    # agreed_terms_version is what the booking is stamped with; only
    # Registry::Terms::record_agreement writes it, as the version /terms serves.
    for my $form ( { agreed_terms_version => 'planted' }, { 'agreed_terms_version[v]' => 'planted' } ) {
        my $run = run_on_second_step();
        $t->post_ok("/run-data-test/${\ $run->id}/complete" => form => $form)->status_is(201);
        ok !exists data_for($run->id)->{agreed_terms_version}, 'a posted agreed_terms_version is not stored';
    }
    $t->post_ok('/run-data-test' => form => { agreed_terms_version => 'planted' })->status_is(302);
    my ($run_id) = $t->tx->res->headers->location =~ m{/run-data-test/([^/]+)/};
    ok !exists data_for($run_id)->{agreed_terms_version}, 'nor at run creation';
};

subtest 'a booking refund cannot be planted by a client' => sub {
    # booking_refund names the payment CompleteBooking refunds; only it writes
    # it, for the run's own payment, when the paid booking cannot be made.
    for my $form ( { booking_refund => 'planted' }, { 'booking_refund[payment_id]' => 'planted' } ) {
        my $run = run_on_second_step();
        $t->post_ok("/run-data-test/${\ $run->id}/complete" => form => $form)->status_is(201);
        ok !exists data_for($run->id)->{booking_refund}, 'a posted booking_refund is not stored';
    }
    $t->post_ok('/run-data-test' => form => { booking_refund => 'planted' })->status_is(302);
    my ($run_id) = $t->tx->res->headers->location =~ m{/run-data-test/([^/]+)/};
    ok !exists data_for($run_id)->{booking_refund}, 'nor at run creation';
};

subtest 'a session cart and its owed charge cannot be planted by a client' => sub {
    # SessionCart writes cart_lines, each line one it would offer the payer;
    # owed_payment is the amount and lines the payment step charges; cart_holds
    # names the hold each line converts; checkout_outcome is each line booked
    # or refunded. Planted, any is a child, a price, an amount, a hold or a
    # booking of the client's choosing.
    for my $key (qw( cart_lines owed_payment cart_holds checkout_outcome )) {
        for my $form ( { $key => 'planted' }, { "${key}[amount_cents]" => 1 }, { "${key}[0][offer_version_id]" => 'planted' } ) {
            my $run = run_on_second_step();
            $t->post_ok("/run-data-test/${\ $run->id}/complete" => form => $form)->status_is(201);
            ok !exists data_for($run->id)->{$key}, "a posted $key is not stored";
        }
        $t->post_ok('/run-data-test' => form => { $key => 'planted' })->status_is(302);
        my ($run_id) = $t->tx->res->headers->location =~ m{/run-data-test/([^/]+)/};
        ok !exists data_for($run_id)->{$key}, 'nor at run creation';
    }
};

subtest 'a stored Stripe event cannot be named by a client' => sub {
    # stripe_event_id names the stored Connect event an entitlement-stripe-move
    # run applies; only the Connect endpoint sets it, when it creates the run.
    for my $form ( { stripe_event_id => 'evt_planted' }, { 'stripe_event_id[x]' => 'evt_planted' } ) {
        my $run = run_on_second_step();
        $t->post_ok("/run-data-test/${\ $run->id}/complete" => form => $form)->status_is(201);
        ok !exists data_for($run->id)->{stripe_event_id}, 'a posted stripe_event_id is not stored';
    }
    $t->post_ok('/run-data-test' => form => { stripe_event_id => 'evt_planted' })->status_is(302);
    my ($run_id) = $t->tx->res->headers->location =~ m{/run-data-test/([^/]+)/};
    ok !exists data_for($run_id)->{stripe_event_id}, 'nor at run creation';
};

subtest 'a step result signal cannot be planted in run data' => sub {
    # retry is a step's "fail this driver attempt" signal; stored in run data it
    # would make every later driver attempt fail and halt the run.
    for my $form ( { retry => 'Not your call' }, { 'retry[x]' => 'Not your call' } ) {
        my $run = run_on_second_step();
        $t->post_ok("/run-data-test/${\ $run->id}/complete" => form => $form)->status_is(201);
        ok !exists data_for($run->id)->{retry}, 'a posted retry is not stored';
    }
};

subtest 'submitted seller account or tenant slug is ignored' => sub {
    # The host tenant sells on its own account; the victim's account is what an
    # attacker would like the charge to land on instead.
    $dao->db->query( q{UPDATE registry.tenants SET stripe_connect_account_id = 'acct_host',
                         stripe_charges_enabled = TRUE, stripe_details_submitted = TRUE
                        WHERE slug = 'hosttenant'} );
    Test::Registry::Fixtures::create_tenant( $dao->db, { name => 'Victim', slug => 'victim_tenant' } );
    $dao->db->query( q{UPDATE registry.tenants SET stripe_connect_account_id = 'acct_victim'
                        WHERE slug = 'victim_tenant'} );

    # Posted: neither key reaches the run.
    $t->post_ok('/run-data-test' => { Host => 'hosttenant.localhost' } => form => {
        __tenant_slug => 'victim_tenant', stripe_account_id => 'acct_victim',
    })->status_is(302);
    my ($run_id) = $t->tx->res->headers->location =~ m{/run-data-test/([^/]+)/};
    my $stored = data_for($run_id);
    is $stored->{__tenant_slug}, 'hosttenant', 'the posted seller slug is not stored';
    ok !exists $stored->{stripe_account_id}, 'the posted seller account is not stored';

    # Planted anyway, in run data and in the submitted form: the real payment
    # step still charges the cart's own tenant on its own account.
    my $tdb    = $dao->connect_schema('hosttenant')->db;
    my $parent = Registry::DAO::User->create( $tdb, {
        username => 'seller_parent', email => 'seller_parent@example.com',
        name => 'Seller Parent', user_type => 'parent' } );
    my $child = Registry::DAO::Family->add_child( $tdb, $parent->id, {
        child_name => 'Seller Child', birth_date => '2018-03-15', grade => '3',
        medical_info => {}, emergency_contact => { name => 'E', phone => '555-0100' } } );
    my $session = Registry::DAO::Session->create( $tdb, {
        name => 'Seller Week', start_date => '2026-07-01', end_date => '2026-07-07',
        status => 'published', capacity => 20, metadata => {} } );
    Registry::DAO::PricingPlan->create( $tdb, {
        session_id => $session->id, plan_name => 'Standard', plan_type => 'standard',
        amount_cents => 15_000 } );
    my $wf = Registry::DAO::Workflow->create( $tdb, {
        name => 'Seller Pay', slug => 'seller-pay', description => 'Payment step only' } );
    Registry::DAO::WorkflowStep->create( $tdb, {
        workflow_id => $wf->id, slug => 'payment',
        class => 'Registry::DAO::WorkflowSteps::Payment', description => 'Payment' } );
    $wf->update( $tdb, { first_step => 'payment' }, { id => $wf->id } );

    my $run = $wf->new_run($tdb);
    $run->update_data( $tdb, {
        user_id            => $parent->id,
        children           => [ { id => $child->id, first_name => 'Seller', last_name => 'Child',
                                  birth_date => '2018-03-15', grade => '3' } ],
        session_selections => { $child->id => $session->id },
        enrollment_items   => [ { child_id => $child->id, session_id => $session->id } ],
        __tenant_slug      => 'hosttenant',
        stripe_account_id  => 'acct_victim',
    } );

    my $account;
    {
        no warnings 'redefine';
        local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';
        local *Registry::Service::Stripe::create_payment_intent_async = sub ( $self, $params ) {
            $account = $self->stripe_account;
            return Mojo::Promise->resolve( { id => 'pi_seller', client_secret => 'cs_seller' } );
        };
        settle( $wf->get_step( $tdb, { slug => 'payment' } )->process( $tdb, {
            agreeTerms => 1, __tenant_slug => 'victim_tenant', stripe_account_id => 'acct_victim',
        }, $run ) );
    }

    is $account, 'acct_host', "the charge is made on the cart's own tenant account";
};

subtest 'a posted tenant id is ignored and signup provisions a new tenant' => sub {
    # The signup commit reads run data's tenant as "already provisioned"; a
    # posted one would skip provisioning and show another tenant's plan.
    $dao->import_workflows( ['workflows/tenant-signup.yml'] );
    my $existing = $dao->db->query( q{SELECT id FROM registry.tenants WHERE slug = 'hosttenant'} )
        ->hash->{id};

    $t->post_ok( '/tenant-signup' => form => { tenant => $existing } )->status_is(302);
    my $url = $t->tx->res->headers->location;
    $t->post_ok( $url => form => { name => 'Planted Studio', tenant => $existing } )->status_is(302);
    $url = $t->tx->res->headers->location;
    $t->post_ok( $url => form => {
        admin_name => 'Planted Admin', admin_email => 'planted_admin@example.com',
        admin_username => 'planted_admin', admin_user_type => 'admin', tenant => $existing,
    } )->status_is(302);
    $url = $t->tx->res->headers->location;
    $t->post_ok( $url => form => {
        terms_accepted => 1, tenant => $existing,
        offer_version  => $solo_now->id,    # Solo's current version, published above
    } )->status_is(302);

    my ($run_id) = $url =~ m{/tenant-signup/([^/]+)/};
    my $tenant = data_for($run_id)->{tenant};
    isnt $tenant, $existing, 'the run does not name the posted tenant';
    my $row = $dao->db->query( 'SELECT slug FROM registry.tenants WHERE id = ?', $tenant )->hash;
    is $row && $row->{slug}, 'planted_studio', 'a new tenant was provisioned for this signup';
};

# authenticate_as installs a permanent before_dispatch hook, so every request
# from here on is authenticated. Keep this subtest last.
subtest 'user_id comes from the session, not the request' => sub {
    authenticate_as($t, $session_user);
    my $run = run_on_second_step();

    $t->post_ok("/run-data-test/${\ $run->id}/complete" => form => {
        user_id => $other_user->id,
    })->status_is(201);

    is data_for($run->id)->{user_id}, $session_user->id,
        'the authenticated user wins over the posted user_id';
};

done_testing;
