#!/usr/bin/env perl
# ABOUTME: An operator can retry and remove jobs from Minion's dashboard form, which carries no CSRF token.
# ABOUTME: Its posts are accepted from the app's own origin only; a cross-site or origin-less post is refused.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw( authenticate_as );
use Registry::DAO::Tenant;

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;
$ENV{DB_URL} = $test_db->uri;

my $alex = Registry::DAO::Tenant->platform($db)->primary_user($db);

# Plain Test::Mojo on purpose: Test::Registry::Mojo adds a CSRF token to every
# form post, and the point here is a browser submitting Minion's own form,
# which has none.
my $t = Test::Mojo->new('Registry');
$t->ua->max_redirects(0);
authenticate_as( $t, $alex );
my $minion = $t->app->minion;
my $own    = $t->ua->server->url->path('')->to_string =~ s{/\z}{}r;

# What form_for 'minion_manage_jobs' renders: a POST carrying _method=PATCH.
sub dashboard_post ( $id, $do, %headers ) {
    $t->post_ok( '/platform/jobs/jobs?_method=PATCH' => \%headers => form => { id => $id, do => $do } );
}

sub a_job { $minion->enqueue( 'csrf_probe', [], { queue => 'csrf_probe' } ) }

subtest 'an operator can remove a job from the dashboard form' => sub {
    my $id = a_job();
    dashboard_post( $id, 'remove', Origin => $own )->status_is( 302, 'the dashboard handles it' );
    ok !$minion->job($id), 'and the job is gone';
};

subtest 'an operator can retry a job from the dashboard form' => sub {
    my $id = a_job();
    dashboard_post( $id, 'retry', Referer => "$own/platform/jobs" )->status_is( 302, 'a same-origin Referer will do' );
    is $minion->job($id)->info->{retries}, 1, 'and the job was retried';
};

subtest 'a cross-site post to the dashboard is refused' => sub {
    my $id = a_job();
    dashboard_post( $id, 'remove', Origin => 'https://evil.example' )->status_is(403);
    ok $minion->job($id), 'the job is still there';
};

subtest 'a dashboard post with neither origin nor referer is refused' => sub {
    my $id = a_job();
    dashboard_post( $id, 'remove' )->status_is(403);
    ok $minion->job($id), 'the job is still there';
};

subtest 'a PATCH without a token is checked like any state change' => sub {
    my $id = a_job();
    $t->patch_ok( '/platform/jobs/jobs' => { Origin => 'https://evil.example' } => form => { id => $id, do => 'remove' } )
      ->status_is(403);
    ok $minion->job($id), 'the job is still there';
};

done_testing;
