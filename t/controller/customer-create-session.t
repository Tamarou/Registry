use 5.38.0;
use lib          qw(lib t/lib);
use experimental qw(defer builtin declared_refs);
use builtin      qw(blessed);

use Test::Mojo;
use Test::More import => [qw( done_testing is note ok )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB qw(DAO Workflow WorkflowRun WorkflowStep);
my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );

$ENV{DB_URL} = $dao->url;

my $t = Test::Mojo->new('Registry');
{

    my sub get_form ( $url, $headers ) {
        my $form = $t->get_ok( $url, $headers )->status_is(200)
          ->tx->res->dom->at('form');
        return unless $form;

        my $action = $form->attr('action');
        return unless $action;

        my @fields =
          $form->find('input')
          ->grep( sub ( $field = $_ ) { $field->attr('name') } )
          ->map( sub ( $f      = $_ ) { $f->attr('name') } )->to_array->@*;
        my @workflows =
          $form->find('a')
          ->grep( sub ( $a = $_ ) { $a->attr('rel') =~ /\bcreate-page\b/ } )
          ->map( sub ( $a  = $_ ) { $a->attr('href') } )->to_array->@*;
        return $action, \@fields, \@workflows;
    }

    my sub submit_form ( $url, $headers, %data ) {
        my $req = $t->post_ok( $url, $headers, form => \%data );
        if ( $req->tx->res->code == 302 ) {
            return $req->status_is(302)->tx->res->headers->location;
        }
        if ( $req->tx->res->code == 201 ) {
            $req->status_is(201);
            return;
        }
        else {
            die "Unexpected response code: " . $req->tx->res->code;
        }
    }

    my sub process_workflow ( $start, $data, $headers = {}, ) {
        note "starting processing: $start";
        state %seen;    # only process each sub-workflow once
        my $url = $start;
        while ($url) {
            my ( $action, \@fields, \@workflows ) = get_form( $url, $headers );
            for my $workflow (@workflows) {
                next
                  if $seen{ [ split( '/', $workflow ) ]->[-1] }++;
                note "start sub-workflow: $workflow";
                __SUB__->(
                    submit_form( $workflow, $headers, $data->%{@fields} ),
                    $data, $headers
                );
                note "done sub-workflow: $workflow";
            }
            $url = submit_form( $action, $headers, $data->%{@fields} );
        }
        note "done processing: $start";
    }

    process_workflow(
        '/customer-signup' => {
            name     => 'Test Customer',
            username => 'Alice',
            password => 'password',
        }
    );
    ok my ($customer) = $dao->find( Customer => { name => 'Test Customer' } ),
      'got customer';
    is $customer->primary_user( $dao->db )->username, 'Alice',
      'Primary user is correct';

    ok my $customer_dao = $dao->connect_schema( $customer->slug ),
      'connected to customer schema';
    ok $customer_dao->find( User => { username => 'Alice' } ),
      'found Alice in the customer schema';

    $t->get_ok( '/user-creation', { 'X-As-Customer' => $customer->slug } )
      ->status_is(200);
    {
        process_workflow(
            '/user-creation' => {
                username => 'Bob',
                password => 'password',
            },
            { 'X-As-Customer' => $customer->slug }
        );
        ok $customer_dao->find( User => { username => 'Bob' } ),
          'found bob in the customer schema';
        is $dao->find( User => { username => 'Bob' } ), undef,
          'Bob not in the main schema';
    }

    # customes can create sessions
    {
        use Time::Piece qw( localtime );
        my $time = localtime;
        process_workflow(
            '/session-creation' => {
                name       => 'Test Session',
                time       => $time->datetime,
                teacher_id => $customer->primary_user( $dao->db )->id,
            },
            { 'X-As-Customer' => $customer->slug }
        );
    }
}
