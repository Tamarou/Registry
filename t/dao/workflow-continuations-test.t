use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw(plan done_testing is ok like note)];

defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
use Test::Registry::Fixtures;

my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );

# Basic continuation functionality
{
    note("Testing basic continuation functionality");

    # Create a parent workflow
    my $parent = $dao->create(
        Workflow => {
            slug => 'parent-workflow',
            name => "Parent Workflow",
        }
    );

    $parent->add_step(
        $dao->db,
        {
            slug        => 'landing',
            description => 'Initial step',
        }
    );

    $parent->add_step(
        $dao->db,
        {
            slug        => 'middle',
            description => 'Middle step',
        }
    );

    $parent->add_step(
        $dao->db,
        {
            slug        => 'final',
            description => 'Final step',
        }
    );

    # Create a child workflow
    my $child = $dao->create(
        Workflow => {
            slug => 'child-workflow',
        name => "Child Workflow",
        }
    );

    $child->add_step(
        $dao->db,
        {
            slug        => 'landing',
            description => 'Initial step',
        }
    );

    $child->add_step(
        $dao->db,
        {
            slug        => 'processing',
            description => 'Processing step',
        }
    );

    $child->add_step(
        $dao->db,
        {
            slug        => 'complete',
            description => 'Completion step',
        }
    );

    # Start the parent workflow
    my $parent_run = $parent->new_run( $dao->db );
    $parent_run->process(
        $dao->db,
        $parent->first_step( $dao->db ),
        { parent_data => "initial" }
    );

    # Create a child workflow run with continuation to parent
    my $child_run =
      $child->new_run( $dao->db, { continuation_id => $parent_run->id } );

    # Verify the continuation relationship
    ok $child_run->has_continuation, "Child run has continuation set";
    my ($continuation) = $child_run->continuation( $dao->db );
    is $continuation->id, $parent_run->id, "Continuation points to parent run";

    # Process the child workflow
    $child_run->process(
        $dao->db,
        $child->first_step( $dao->db ),
        { child_data => "started" }
    );

    # Add more data to child
    $child_run->process(
        $dao->db,
        $child_run->next_step( $dao->db ),
        { processed_value => 42 }
    );

    # Complete the child workflow
    $child_run->process(
        $dao->db,
        $child_run->next_step( $dao->db ),
        { child_status => "completed" }
    );

    # Verify child workflow is completed
    is $child_run->completed( $dao->db ), 1, "Child workflow is completed";

    # Verify parent data is still intact
    ($parent_run) = $dao->find( WorkflowRun => { id => $parent_run->id } );
    is $parent_run->data->{parent_data}, "initial", "Parent data is preserved";

    # Continue with parent workflow
    $parent_run->process(
        $dao->db,
        $parent_run->next_step( $dao->db ),
        { parent_status => "in progress" }
    );

    # Complete parent workflow
    $parent_run->process(
        $dao->db,
        $parent_run->next_step( $dao->db ),
        { parent_status => "completed" }
    );

    # Verify both workflows are completed correctly
    is $parent_run->completed( $dao->db ), 1, "Parent workflow is completed";
    ($child_run) = $dao->find( WorkflowRun => { id => $child_run->id } );
    is $child_run->completed( $dao->db ), 1,
      "Child workflow is still completed";
}

# Specialized workflow step with continuation support
{
    note("Testing specialized workflow step with continuation");

    # Create a workflow for creating a project
    my $project_workflow = $dao->create(
        Workflow => {
            slug => 'project-creation',
        name => "Project Creation Workflow",
        }
    );

    $project_workflow->add_step(
        $dao->db,
        {
            slug        => 'project-details',
            description => 'Enter project details',
        }
    );

    $project_workflow->add_step(
        $dao->db,
        {
            slug        => 'create-project',
            description => 'Create project in system',
        }
    );

    # Create a parent workflow that will use project creation as a continuation
    my $parent_workflow = $dao->create(
        Workflow => {
            slug => 'parent-with-project',
        name => "Parent With Project",
        }
    );

    $parent_workflow->add_step(
        $dao->db,
        {
            slug        => 'landing',
            description => 'Initial step',
        }
    );

    $parent_workflow->add_step(
        $dao->db,
        {
            slug        => 'completion',
            description => 'Final step',
        }
    );

    # Start the parent workflow
    my $parent_run = $parent_workflow->new_run( $dao->db );
    $parent_run->process(
        $dao->db,
        $parent_workflow->first_step( $dao->db ),
        { parent_data => "initialized" }
    );

    # Create a project workflow run as a continuation of the parent
    my $project_run = $project_workflow->new_run( $dao->db,
        { continuation_id => $parent_run->id } );

    # Create necessary objects first
    my $project = Test::Registry::Fixtures::create_project(
        $dao, {
            name  => "Test Project",
            notes => "Created during workflow continuations test"
        }
    );

    # Process the project workflow
    $project_run->process(
        $dao->db,
        $project_workflow->first_step( $dao->db ),
        {
            name     => "Test Project",
            notes    => "Created during test",
            projects => [ $project->id ]       # Include the project ID directly
        }
    );

    # Process the specialized step that creates a project
    my $create_step =
      $project_workflow->get_step( $dao->db, { slug => 'create-project' } );

    # Process the project creation step
    $project_run->process(
        $dao->db,
        $create_step,
        {
# The CreateProject step will use this data from the workflow run
# We don't need to pass new data here because we've already set it in the previous step
        }
    );

    # Verify project workflow is completed
    is $project_run->completed( $dao->db ), 1, "Project workflow is completed";

    # Verify project data is in the project workflow
    ($project_run) = $dao->find( WorkflowRun => { id => $project_run->id } );
    is $project_run->data->{projects}[0], $project->id,
      "Project ID is stored in project workflow data";

    # Verify parent data is still intact
    ($parent_run) = $dao->find( WorkflowRun => { id => $parent_run->id } );
    is $parent_run->data->{parent_data}, "initialized", "Parent data is preserved";

    # Complete parent workflow
    $parent_run->process(
        $dao->db,
        $parent_run->next_step( $dao->db ),
        { status => "completed with project" }
    );

    is $parent_run->completed( $dao->db ), 1, "Parent workflow is completed";
}

# Multi-level workflow continuations
{
    note("Testing multi-level workflow continuations");

    # Create a grandparent workflow
    my $grandparent = $dao->create(
        Workflow => {
            slug => 'grandparent',
        name => "Grandparent Workflow",
        }
    );

    $grandparent->add_step(
        $dao->db,
        {
            slug        => 'start',
            description => 'Start step',
        }
    );

    $grandparent->add_step(
        $dao->db,
        {
            slug        => 'end',
            description => 'End step',
        }
    );

    # Create parent workflow
    my $parent = $dao->create(
        Workflow => {
            slug => 'multi-level-parent',
        name => "Multi-Level Parent Workflow",
        }
    );

    $parent->add_step(
        $dao->db,
        {
            slug        => 'start',
            description => 'Start step',
        }
    );

    $parent->add_step(
        $dao->db,
        {
            slug        => 'end',
            description => 'End step',
        }
    );

    # Create child workflow
    my $child = $dao->create(
        Workflow => {
            slug => 'multi-level-child',
        name => "Multi-Level Child Workflow",
        }
    );

    $child->add_step(
        $dao->db,
        {
            slug        => 'start',
            description => 'Start step',
        }
    );

    $child->add_step(
        $dao->db,
        {
            slug        => 'end',
            description => 'End step',
        }
    );

    # Start the grandparent workflow
    my $grandparent_run = $grandparent->new_run( $dao->db );
    $grandparent_run->process(
        $dao->db,
        $grandparent->first_step( $dao->db ),
        { level => "grandparent", value => 1 }
    );

    # Start the parent workflow as a continuation of grandparent
    my $parent_run =
      $parent->new_run( $dao->db, { continuation_id => $grandparent_run->id } );
    $parent_run->process(
        $dao->db,
        $parent->first_step( $dao->db ),
        { level => "parent", value => 2 }
    );

    # Start the child workflow as a continuation of parent
    my $child_run =
      $child->new_run( $dao->db, { continuation_id => $parent_run->id } );
    $child_run->process(
        $dao->db,
        $child->first_step( $dao->db ),
        { level => "child", value => 3 }
    );

    # Complete each workflow in reverse order
    $child_run->process(
        $dao->db,
        $child_run->next_step( $dao->db ),
        { child_complete => 1 }
    );

    $parent_run->process(
        $dao->db,
        $parent_run->next_step( $dao->db ),
        { parent_complete => 1 }
    );

    $grandparent_run->process(
        $dao->db,
        $grandparent_run->next_step( $dao->db ),
        { grandparent_complete => 1 }
    );

    # Verify each workflow is completed
    is $child_run->completed( $dao->db ),  1, "Child workflow is completed";
    is $parent_run->completed( $dao->db ), 1, "Parent workflow is completed";
    is $grandparent_run->completed( $dao->db ), 1,
      "Grandparent workflow is completed";

    # Verify continuation chain
    ok $child_run->has_continuation, "Child has continuation";
    is $child_run->continuation( $dao->db )->id, $parent_run->id,
      "Child continues to parent";

    ok $parent_run->has_continuation, "Parent has continuation";
    is $parent_run->continuation( $dao->db )->id, $grandparent_run->id,
      "Parent continues to grandparent";

    ok !$grandparent_run->has_continuation, "Grandparent has no continuation";
}

# Test creating a workflow-as-a-step (workflow composition)
{
    note("Testing workflow composition (workflow-as-a-step)");

  # Define a simple workflow that will be embedded as a step in another workflow
    my $subworkflow = $dao->create(
        Workflow => {
            slug => 'subworkflow',
        name => "Subworkflow",
        }
    );

    $subworkflow->add_step(
        $dao->db,
        {
            slug        => 'sub-landing',
            description => 'Subworkflow first step',
        }
    );

    $subworkflow->add_step(
        $dao->db,
        {
            slug        => 'sub-final',
            description => 'Subworkflow final step',
        }
    );

    # Create a main workflow
    my $main_workflow = $dao->create(
        Workflow => {
            slug => 'main-workflow',
        name => "Main Workflow",
        }
    );

    $main_workflow->add_step(
        $dao->db,
        {
            slug        => 'main-start',
            description => 'Main workflow first step',
        }
    );

    # This step will act as a "connector" to the subworkflow
    $main_workflow->add_step(
        $dao->db,
        {
            slug        => 'init-subworkflow',
            description => 'Initialize subworkflow',

            # In a real implementation, this might be a specialized class that
            # creates and manages the subworkflow run
        }
    );

    $main_workflow->add_step(
        $dao->db,
        {
            slug        => 'main-final',
            description => 'Main workflow final step',
        }
    );

    # Start the main workflow
    my $main_run = $main_workflow->new_run( $dao->db );
    $main_run->process(
        $dao->db,
        $main_workflow->first_step( $dao->db ),
        { main_data => "initialized" }
    );

# When we reach the subworkflow step, we simulate creating and running a subworkflow
    my $init_step =
      $main_workflow->get_step( $dao->db, { slug => 'init-subworkflow' } );

    # In a real scenario, this would be done by a specialized step class
    {
# Process the init step first (which in a real implementation would create the subworkflow)
        $main_run->process( $dao->db, $init_step,
            { subworkflow_initialized => 1 } );

        # Now manually create and run the subworkflow as a continuation
        my $sub_run = $subworkflow->new_run( $dao->db,
            { continuation_id => $main_run->id } );

        # Execute the subworkflow
        $sub_run->process(
            $dao->db,
            $subworkflow->first_step( $dao->db ),
            { sub_data => "processing" }
        );

        $sub_run->process(
            $dao->db,
            $sub_run->next_step( $dao->db ),
            { sub_data => "completed", sub_result => "success" }
        );

        # Verify subworkflow completed
        is $sub_run->completed( $dao->db ), 1,
          "Subworkflow completed successfully";

# In a real implementation, a specialized step would detect the subworkflow completion
# and proceed with the main workflow automatically
    }

    # Complete the main workflow
    $main_run->process(
        $dao->db,
        $main_run->next_step( $dao->db ),
        { main_status => "completed" }
    );

    is $main_run->completed( $dao->db ), 1, "Main workflow completed";

 # Verify data flow - in a real implementation, the specialized step class would
 # copy important data from subworkflow to main workflow
    ($main_run) = $dao->find( WorkflowRun => { id => $main_run->id } );
    is $main_run->data->{main_data}, "initialized",
      "Main workflow data preserved";
    is $main_run->data->{subworkflow_initialized}, 1,
      "Subworkflow initialization recorded";
}
