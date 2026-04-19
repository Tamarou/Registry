#!/usr/bin/env perl
# ABOUTME: Controller tests for admin publish/unpublish endpoints.
# ABOUTME: Admins toggle program and session publish state from the dashboard.
use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Registry;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw(authenticate_as);
use Registry::DAO::Project;
use Registry::DAO::Session;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

my $t = Test::Registry::Mojo->new('Registry');

# Create an admin user and authenticate.
my $admin = $dao->create(User => {
    username  => 'victoria_admin',
    name      => 'Victoria',
    email     => 'victoria@test.local',
    user_type => 'admin',
    password  => 'x',
});
authenticate_as($t, $admin);

# Create a draft program that Victoria is about to publish.
my $program = Test::Registry::Fixtures::create_project($dao, {
    name   => 'Draft Art Program',
    status => 'draft',
});

subtest 'admin can publish a draft program' => sub {
    $t->post_ok("/admin/programs/@{[ $program->id ]}/status" => form => {
        status => 'published',
    })->status_is(200, 'returns 200')
      ->content_like(qr/published/i, 'response confirms new status');

    my $refreshed = Registry::DAO::Project->find($dao->db, { id => $program->id });
    is( $refreshed->status, 'published', 'program is published in DB' );
};

subtest 'admin can unpublish back to draft' => sub {
    $t->post_ok("/admin/programs/@{[ $program->id ]}/status" => form => {
        status => 'draft',
    })->status_is(200, 'returns 200');

    my $refreshed = Registry::DAO::Project->find($dao->db, { id => $program->id });
    is( $refreshed->status, 'draft', 'program back to draft' );
};

subtest 'invalid status is rejected' => sub {
    $t->post_ok("/admin/programs/@{[ $program->id ]}/status" => form => {
        status => 'weird',
    })->status_is(400, 'returns 400 on invalid status');

    my $refreshed = Registry::DAO::Project->find($dao->db, { id => $program->id });
    is( $refreshed->status, 'draft', 'program status unchanged' );
};

subtest 'non-existent program returns 404' => sub {
    $t->post_ok(
        '/admin/programs/00000000-0000-0000-0000-000000000000/status' => form => {
            status => 'published',
        }
    )->status_is(404, 'returns 404 for unknown id');
};

subtest 'session publish toggle' => sub {
    # Session must belong to a published program before it can be
    # published itself -- create the program, a linking event, then
    # the session.
    require Registry::DAO::Location;
    require Registry::DAO::Event;
    my $location = Registry::DAO::Location->create($dao->db, {
        name => 'Session Toggle Location', address_info => {},
    });
    my $published_program = Registry::DAO::Project->create($dao->db, {
        name => 'Parent Program', status => 'published',
    });
    my $session = Registry::DAO::Session->create($dao->db, {
        name   => 'Draft Session',
        status => 'draft',
    });
    Registry::DAO::Event->create($dao->db, {
        session_id  => $session->id,
        time        => '2099-07-04 09:00:00',
        duration    => 60,
        location_id => $location->id,
        project_id  => $published_program->id,
        teacher_id  => $admin->id,
    });

    $t->post_ok("/admin/sessions/@{[ $session->id ]}/status" => form => {
        status => 'published',
    })->status_is(200, 'session status update returns 200');

    my $refreshed = Registry::DAO::Session->find($dao->db, { id => $session->id });
    is( $refreshed->status, 'published', 'session is published' );
};

subtest 'cannot publish a session under a draft program' => sub {
    require Registry::DAO::Location;
    require Registry::DAO::Event;
    my $location = Registry::DAO::Location->create($dao->db, {
        name => 'Draft Parent Location', address_info => {},
    });
    my $draft_program = Registry::DAO::Project->create($dao->db, {
        name => 'Not-Yet-Public Program', status => 'draft',
    });
    my $session = Registry::DAO::Session->create($dao->db, {
        name   => 'Orphaned Session',
        status => 'draft',
    });
    Registry::DAO::Event->create($dao->db, {
        session_id  => $session->id,
        time        => '2099-08-04 09:00:00',
        duration    => 60,
        location_id => $location->id,
        project_id  => $draft_program->id,
        teacher_id  => $admin->id,
    });

    $t->post_ok("/admin/sessions/@{[ $session->id ]}/status" => form => {
        status => 'published',
    })->status_is(409, 'returns 409 Conflict')
      ->content_like(qr/parent program must be published/i,
                     'error message names the reason');

    my $refreshed = Registry::DAO::Session->find($dao->db, { id => $session->id });
    is( $refreshed->status, 'draft', 'session remains draft' );
};

subtest 'unauthenticated users cannot toggle status' => sub {
    my $anon = Test::Registry::Mojo->new('Registry');

    $anon->post_ok("/admin/programs/@{[ $program->id ]}/status" => form => {
        status => 'published',
    });

    # Either 302 redirect to login or 401/403 -- whichever the app does.
    my $code = $anon->tx->res->code;
    ok( $code == 302 || $code == 401 || $code == 403,
        "unauthenticated request is rejected (got $code)" );
};

done_testing();
