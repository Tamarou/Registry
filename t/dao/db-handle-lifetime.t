use 5.42.0;
# ABOUTME: A db handle must stay usable after the DAO that made it is gone, because
# ABOUTME: handles outlive their DAO whenever a workflow step defers to Stripe.
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw(done_testing ok subtest diag)];
defer { done_testing };

use Test::Mojo;
use Registry::DAO;
use Test::Registry::DB;

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
$ENV{DB_URL} = $t_db->uri;

# Mojo::Pg::Database weakens its pg attribute, so a handle whose DAO has been
# freed loses ->pg. Raw query() never touches pg and keeps working; only the
# abstract-SQL methods break, and in the money path they break inside a promise
# where the failure reads as a generic workflow error.
sub still_usable ( $db, $label ) {
    ok defined $db->pg, "$label: handle still has its Mojo::Pg";
    my $ok = eval { $db->select( 'workflows', '*', undef, { limit => 1 } ); 1 };
    ok $ok, "$label: select still works" or diag $@;
}

subtest 'handle outlives the DAO that made it' => sub {
    my $db = do { Registry::DAO->new( url => $ENV{DB_URL} )->db };
    still_usable( $db, 'bare DAO' );
};

subtest 'the two call shapes that hand a handle to something async' => sub {
    my $t = Test::Mojo->new('Registry');

    # Workflows::process_workflow_run_step: `my $dao = $self->dao;` is a method
    # lexical, and the handle it gives the step is used again when the step's
    # Stripe promise settles -- long after the method has returned.
    my $c  = $t->app->build_controller;
    my $db = do { my $dao = $c->dao; $dao->db };
    still_usable( $db, 'controller' );

    # Job::DomainVerification::run discards the DAO on the line that makes it and
    # then selects with the handle. Bind to a lexical first: a DAO left as a
    # statement temporary survives to the end of the statement, so inlining this
    # into the call below would hide the very thing it is meant to catch.
    my $job_db = $t->app->dao('registry')->db;
    still_usable( $job_db, 'job' );
};
