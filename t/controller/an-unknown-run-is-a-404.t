#!/usr/bin/env perl
# ABOUTME: An unknown workflow slug or run id answers 404, not 500, and logs no database error.
# ABOUTME: Crawler traffic was hitting /<workflow>/session/<step> and raising an invalid-uuid cast.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Mojo::JSON qw(decode_json);
use Test::Registry::Mojo;
use Test::Registry::DB;
use Registry::DAO::Workflow;
use Mojo::Home;
use YAML::XS qw(Load);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

for my $file ( Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each ) {
    next if Load( $file->slurp )->{draft};
    Registry::DAO::Workflow->from_yaml( $dao, $file->slurp );
}

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $dao } );
$t->app->log->level('debug');

# The app's own log, so a request can be graded on what it wrote as well as on
# what it returned. The production symptom was a log line, not a status code.
my $log = '';
sub capture ( $code ) {
    $log = '';
    open my $fh, '>', \$log or die "cannot open scalar handle: $!";
    $t->app->log->handle($fh);
    $code->();
    return $log;
}

subtest 'an unknown workflow slug is not found' => sub {
    capture( sub { $t->get_ok('/no-such-workflow-anywhere')->status_is(404) } );

    unlike $log, qr/Can't call method/,
        'and nothing dereferenced the workflow that does not exist';
};

subtest 'a well-formed run id that matches nothing is not found' => sub {
    # The issue's case: the uuid casts fine, the row is absent, and the deref
    # that followed produced a 500 and then "Could not render a response".
    capture( sub {
        $t->get_ok('/tenant-signup/00000000-0000-0000-0000-000000000000/profile')
          ->status_is(404);
    } );

    unlike $log, qr/Can't call method/, 'no undefended dereference';
    unlike $log, qr/Could not render a response/,
        'and the error path itself did not fail';
};

subtest 'a run id that is not a uuid never reaches the database' => sub {
    # What production actually hit, four times an hour from crawler traffic:
    # 'session' is not uuid-shaped, so the cast raised inside the query -- a
    # database error in the log, indistinguishable at a glance from a real one.
    capture( sub { $t->get_ok('/tenant-signup/session/profile')->status_is(404) } );

    unlike $log, qr/invalid input syntax for type uuid/,
        'no invalid-uuid cast reaches Postgres';
    unlike $log, qr/DBD::Pg/, 'and no database error of any kind is logged';
};

subtest 'the same shapes on the POST routes' => sub {
    # process_workflow_run_step resolves the run itself rather than through
    # run(), so it needs the same refusal -- and a POST is what a crawler
    # replaying a form does.
    capture( sub {
        $t->post_ok('/tenant-signup/session/profile')->status_is(404);
        $t->post_ok('/tenant-signup/00000000-0000-0000-0000-000000000000/profile')
          ->status_is(404);
    } );

    unlike $log, qr/invalid input syntax for type uuid|Can't call method/,
        'neither shape raises';
};

subtest 'a real run still works' => sub {
    # The guard must refuse only what does not exist. Without this the whole
    # file passes against a controller that 404s everything.
    my ($workflow) = $dao->find( Workflow => { slug => 'tenant-signup' } );
    my $run = $workflow->new_run( $dao->db );

    # profile, not landing: a run-scoped GET of a step whose template is named
    # something other than the step slug is its own 500, filed separately. This
    # control only needs a step that renders.
    $t->get_ok( "/tenant-signup/${\ $run->id }/profile" )->status_is(200);
};

subtest 'reply->not_found works on a POST at all' => sub {
    # The reason this file needed templates/not_found.html.ep. Without one,
    # Mojolicious falls back to its built-in not-found renderer, and on a POST
    # that path closed the connection instead of answering -- so the refusals
    # above could not use the idiomatic helper. Asserted directly, because the
    # next person to add a 404 will reach for reply->not_found and should not
    # have to rediscover this.
    my $log = capture( sub {
        $t->post_ok('/tenant-signup/00000000-0000-0000-0000-000000000000/profile')
          ->status_is(404)
          ->content_like(qr/not found/i, 'and renders a page a person can read');
    } );

    unlike $log, qr/Premature connection close|Could not render a response/,
        'the refusal completes rather than killing the request';
};

done_testing;
