# ABOUTME: Asserts a multi-step workflow step page renders the progress element with real data.
# ABOUTME: The controller has always computed this; nothing ever put it on a page (#423).
use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is ok cmp_ok like unlike is_deeply subtest note )];
defer { done_testing };

use Test::Mojo;
use Registry;
use Registry::DAO;
use Test::Registry::DB;
use Test::Registry::Helpers qw(import_all_workflows);

my $test_db = Test::Registry::DB->new();
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;

import_all_workflows($dao);

my $t = Test::Mojo->new('Registry');

# Registry has computed this on every workflow step render since the feature was
# written -- ordered steps loaded, walked twice, a URL built per completed step --
# and then discarded it. Three things never lined up: the controller stashed a
# hashref under `workflow_progress` while the layout read five flat keys nobody
# set; the layout's block was gated on `show_workflow_progress`, which nothing
# anywhere sets; and that block emitted a <div data-component="progress-steps">
# when the script defines a custom ELEMENT, which would never have claimed a div.
#
# The page under test is a STEP, not a workflow's landing page. Eight workflows
# ship a {slug}/index template and Workflows#index returns early for those
# without computing progress at all -- right, because a landing page has no
# progress to show yet.
my $workflow = Registry::DAO::Workflow->find( $db, { slug => 'tenant-signup' } );
ok $workflow, 'found the tenant-signup workflow' or exit;

my $steps = $workflow->get_ordered_steps($db);
cmp_ok scalar @$steps, '>', 1,
    'tenant-signup has more than one step, so there is progress to show';

# Second step: the first is `landing`, whose template lives at
# tenant-signup/index and is reached through the early-return path, so a direct
# GET of the step slug has nothing to render.
my $step_slug = $steps->[1]{slug};

subtest 'a step page carries the element the script defines' => sub {
    my $run = $workflow->new_run($db);
    $t->get_ok("/tenant-signup/@{[ $run->id ]}/$step_slug")->status_is(200);

    $t->element_exists( 'workflow-progress',
        'the page emits <workflow-progress>' );

    # The dead markup this replaces: a div the component could never have
    # claimed, behind a stash key nothing sets.
    $t->content_unlike( qr/data-component="progress-steps"/,
        'and not the div the component would never have upgraded' );
};

subtest 'and it carries the data the controller computed' => sub {
    my $run = $workflow->new_run($db);
    $t->get_ok("/tenant-signup/@{[ $run->id ]}/$step_slug")->status_is(200);

    my $el = $t->tx->res->dom->at('workflow-progress');
    ok $el, 'found the element' or return;

    is $el->attr('data-total-steps'), 0 + @$steps,
        'total steps matches the workflow';
    is $el->attr('data-current-step'), 2,
        'and it knows which step this is';

    # The component parses these with split(',') -- workflow-progress.js:37 -- so
    # the contract is a comma-joined list, which is what the controller has
    # always produced. The layout's own default was '[]', a JSON-shaped string
    # that would have rendered a single phantom step named "[]".
    my @names = split /,/, ( $el->attr('data-step-names') // '' );
    is scalar @names, 0 + @$steps, 'one name per step';
    ok !( grep { !/\S/ } @names ), 'and none of them blank';
    note 'steps: ' . join ' | ', @names;

    # These are the labels from the workflow definition, not its developer
    # descriptions ("Tenant users page").
    is_deeply \@names,
        [ 'Welcome', 'Your studio', 'Your account', 'Review and pay', 'Done' ],
        'and they are the labels a person is meant to read';

    # A URL is built only for steps already behind you, which is what makes the
    # labels safe to click: there is nothing to click forward to.
    my @urls = split /,/, ( $el->attr('data-step-urls') // '' ), -1;
    is scalar( grep { /\S/ } @urls ), 1,
        'one navigable URL, for the one completed step';
    is $el->attr('data-completed-steps'), '1', 'and it is step 1';
};

# The gate lives in the layout, so it is tested there. No single-step workflow
# uses this layout today, so an HTTP test of that case would assert absence
# against a page that never had the element for unrelated reasons -- a test that
# passes whatever the gate does. The layout is rendered directly instead, which
# does exercise it: note that `render_to_string` with `layout => ...` does NOT
# work for this, because it disables the layout by design.
sub layout_with ( %stash ) {
    return '' . $t->app->build_controller
      ->render_to_string( template => 'layouts/workflow', %stash );
}

subtest 'the layout decides when there is progress worth showing' => sub {
    my $three = layout_with(
        workflow_progress => {
            current_step    => 2,
            total_steps     => 3,
            step_names      => 'First,Second,Third',
            step_urls       => '/a,,',
            completed_steps => '1',
        },
    );
    like $three, qr/workflow-content/, 'the layout really rendered';
    like $three, qr/<workflow-progress/, 'three steps gets the element';
    like $three, qr/data-step-names="First,Second,Third"/,
        'and the names reach the attribute unmangled';

    my $one = layout_with(
        workflow_progress => {
            current_step    => 1,
            total_steps     => 1,
            step_names      => 'The Only Step',
            step_urls       => '',
            completed_steps => '',
        },
    );
    like $one, qr/workflow-content/, 'the layout really rendered';
    unlike $one, qr/<workflow-progress/,
        'one step is not progress worth indicating';

    # _get_workflow_progress returns {} for a workflow with no ordered steps.
    my $empty = layout_with( workflow_progress => {} );
    like $empty, qr/workflow-content/, 'the layout really rendered';
    unlike $empty, qr/<workflow-progress/, 'and an empty hash shows nothing';

    my $none = layout_with();
    like $none, qr/workflow-content/, 'the layout really rendered';
    unlike $none, qr/<workflow-progress/, 'nor does an absent stash';
};

subtest 'a step carries a label beside its developer description' => sub {
    # `description` is the note for whoever maintains the workflow -- the shipped
    # YAML says "Tenant users page" -- and the CLI listing prints it beside the
    # slug. `label` is what the person being walked through it reads. Different
    # audiences, so two fields, and get_ordered_steps hands both to the caller.
    my $wf = $dao->create( Workflow => {
        slug        => 'labelled-workflow',
        name        => 'Labelled',
        description => 'Two steps, one labelled',
    } );
    # add_step is the real path: it is what links a step into the depends_on
    # chain that get_ordered_steps walks.
    $wf->add_step( $db, {
        slug        => 'first',
        description => 'First page of the labelled workflow',
        label       => 'Your details',
        class       => 'Registry::DAO::WorkflowStep',
    } );
    $wf->add_step( $db, {
        slug        => 'second',
        description => 'Second page of the labelled workflow',
        class       => 'Registry::DAO::WorkflowStep',
    } );

    my $ordered = $wf->get_ordered_steps($db);
    is scalar @$ordered, 2, 'both steps come back';
    is $ordered->[0]{slug}, 'first', 'in chain order, not creation order';
    is $ordered->[1]{slug}, 'second', 'which for a tied created_at is the only honest order';

    is $ordered->[0]{label}, 'Your details', 'the label is carried';
    is $ordered->[0]{description}, 'First page of the labelled workflow',
        'and so is the description it does not replace';
    ok !defined $ordered->[1]{label} || $ordered->[1]{label} !~ /\S/,
        'a step with no label has none, rather than borrowing one';
};
