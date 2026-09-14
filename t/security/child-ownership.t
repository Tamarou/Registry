#!/usr/bin/env perl
# ABOUTME: A payer may only enrol children of their own family.
# ABOUTME: The select-children checkboxes were taken at face value, with no ownership check.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;

use Registry::DAO qw(Workflow);
use Registry::DAO::User;
use Registry::DAO::Family;
use Registry::DAO::WorkflowStep;
use Mojo::Home;
use YAML::XS qw(Load);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

Workflow->from_yaml( $dao,
    Mojo::Home->new->child('workflows/summer-camp-registration.yaml')->slurp );

my $workflow = $dao->find( Workflow => { slug => 'summer-camp-registration' } );
my $step = Registry::DAO::WorkflowStep->find( $db,
    { workflow_id => $workflow->id, slug => 'select-children' } );
ok $step, 'the select-children step exists' or BAIL_OUT 'no step';

sub family_with_child ($tag) {
    my $user = Registry::DAO::User->create( $db, {
        name => "Parent $tag", username => "parent_$tag",
        email => "parent_$tag\@example.com", user_type => 'parent',
    } );
    my $child = Registry::DAO::Family->add_child( $db, $user->id, {
        child_name => "Child $tag",
        birth_date => '2016-05-05',
        grade      => '3',
        emergency_contact => { name => "EC $tag", phone => '555-0100' },
    } );
    return ( $user, $child );
}

my ( $payer,     $own_child )   = family_with_child('payer');
my ( $stranger,  $their_child ) = family_with_child('stranger');

isnt $own_child->id, $their_child->id, 'two distinct children exist';

sub run_for ($user) {
    my $run = $workflow->new_run($db);
    $run->update_data( $db, { user_id => $user->id } );
    return $run;
}

subtest 'a parent may select their own child' => sub {
    my $run = run_for($payer);
    my $result = $step->process( $db,
        { action => 'continue', 'child_' . $own_child->id => 1 }, $run );

    is $result->{next_step}, 'session-selection', 'the cart proceeds';
    is_deeply $run->data->{selected_child_ids}, [ $own_child->id ],
        'and carries exactly that child';
};

# Reproduced end to end in #337: a cart naming another family's child enrolled
# that child under the attacker's parent_id. Child ids are UUIDs, so this needs
# an id leak to target -- an authorization gap rather than an enumeration one.
subtest "a parent may not select another family's child" => sub {
    my $run = run_for($payer);
    my $result = $step->process( $db,
        { action => 'continue', 'child_' . $their_child->id => 1 }, $run );

    isnt $result->{next_step}, 'session-selection', 'the cart does not proceed';
    ok $result->{errors} && @{ $result->{errors} }, 'an error is returned';
    ok !$run->data->{selected_child_ids},
        "and the stranger's child never reaches run data";
};

# The mixed cart matters on its own: taking the valid half and silently dropping
# the rest would still consume a seat under a name the payer does not own if the
# order were reversed, and would hide the attempt.
subtest 'a cart mixing own and foreign children is refused entire' => sub {
    my $run = run_for($payer);
    my $result = $step->process( $db, {
        action => 'continue',
        'child_' . $own_child->id   => 1,
        'child_' . $their_child->id => 1,
    }, $run );

    isnt $result->{next_step}, 'session-selection', 'the whole cart is refused';
    ok !$run->data->{selected_child_ids}, 'nothing is stored';
};

done_testing;
