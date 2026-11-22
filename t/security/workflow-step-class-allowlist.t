#!/usr/bin/env perl
# ABOUTME: A workflow step's class comes from the shipped step classes, never from what a form says.
# ABOUTME: Tenant staff compose allowed steps; naming any other class is refused before it is stored.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Registry::WorkflowStepClasses;

# The hole this closes: workflow-creation stored whatever `class` the form
# submitted, and WorkflowStep::find later ran it through a string
# `eval "require $class"`. Every tenant's admin and staff hold
# workflow-creation, so a staff member could make the shared process load any
# module -- or, through the string eval, run any Perl.
subtest 'is_allowed accepts shipped step classes and refuses everything else' => sub {
    ok Registry::WorkflowStepClasses::is_allowed($_), "$_ is allowed"
      for qw(
      Registry::DAO::WorkflowStep
      Registry::DAO::WorkflowSteps::Payment
      Registry::DAO::WorkflowSteps::AttendanceCheck::UpcomingEventProcessor
    );

    ok !Registry::WorkflowStepClasses::is_allowed($_), "$_ is refused"
      for (
        'IO::Socket::INET',
        'Test::Registry::RunRecorderStep',
        'Registry::DAO::WorkflowSteps::DoesNotExist',
        'Registry::DAO::WorkflowStep; die "pwned"',
      );
};

# Perl's `$` matches before a trailing newline, so a pattern anchored with it
# would let "Registry::DAO::WorkflowSteps::Payment\n" through -- and that string,
# interpolated into a require, is no longer the class it looks like.
subtest 'a shipped class name with a trailing newline is refused' => sub {
    ok !Registry::WorkflowStepClasses::is_allowed("Registry::DAO::WorkflowSteps::Payment\n"),
      'Payment with a trailing newline is refused';
    ok !Registry::WorkflowStepClasses::is_allowed("Registry::DAO::WorkflowStep\n"),
      'the base class with a trailing newline is refused';
};

subtest 'lookalike class names are refused without warnings' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };

    ok !Registry::WorkflowStepClasses::is_allowed($_->[0]), "$_->[1] is refused"
      for (
        [ 'Registry::DAO::WorkflowSteps::payment',        'lower-case class' ],
        [ 'Registry::DAO::WorkflowSteps',                 'bare namespace' ],
        [ 'Registry::DAO::WorkflowSteps::',               'trailing ::' ],
        [ 'Registry::DAO::WorkflowSteps::Payment::',      'shipped class with trailing ::' ],
        [ q{Registry'DAO'WorkflowSteps'Payment},          "old ' separator" ],
        [ 'Registry::DAO::WorkflowSteps::..::..::Tenant', 'path traversal' ],
        [ 'Registry/DAO/WorkflowSteps/Payment',           'slash path' ],
        [ ' Registry::DAO::WorkflowSteps::Payment',       'leading space' ],
        [ 'Registry::DAO::WorkflowSteps::Payment ',       'trailing space' ],
        [ '',                                             'empty string' ],
        [ undef,                                          'undef' ],
      );

    is_deeply \@warnings, [], 'and none of them warned';
};

# @INC under test includes t/lib, and in production it is whatever the process
# was started with. A step file placed anywhere on it must not become allowed:
# the allowlist reads the application's own lib/, located from its own file.
subtest 'a step class planted earlier on the include path is refused' => sub {
    require File::Temp;
    require File::Path;
    my $dir = File::Temp->newdir;
    File::Path::make_path("$dir/Registry/DAO/WorkflowSteps");
    open my $fh, '>', "$dir/Registry/DAO/WorkflowSteps/Planted.pm" or die $!;
    print $fh "package Registry::DAO::WorkflowSteps::Planted; 1;\n";
    close $fh;

    local @INC = ( "$dir", @INC );
    ok !Registry::WorkflowStepClasses::is_allowed('Registry::DAO::WorkflowSteps::Planted'),
      'a step file planted at the front of @INC is not allowed';
};

# The registry script loads lib/ through a relative `use lib`, so __FILE__ is
# relative too. A directory resolved from it at each check would move with the
# working directory: a process that chdir'd somewhere holding a planted
# lib/Registry/DAO/WorkflowSteps/X.pm would allow X.
subtest 'the allowlist directory does not move with the working directory' => sub {
    require Cwd;
    require File::Temp;
    require File::Path;
    my $home = Cwd::getcwd();
    my $dir  = File::Temp->newdir;
    File::Path::make_path("$dir/lib/Registry/DAO/WorkflowSteps");
    open my $fh, '>', "$dir/lib/Registry/DAO/WorkflowSteps/Planted.pm" or die $!;
    print $fh "package Registry::DAO::WorkflowSteps::Planted; 1;\n";
    close $fh;

    chdir "$dir" or die $!;
    my $planted = Registry::WorkflowStepClasses::is_allowed('Registry::DAO::WorkflowSteps::Planted');
    my $shipped = Registry::WorkflowStepClasses::is_allowed('Registry::DAO::WorkflowSteps::Payment');
    chdir $home or die $!;

    ok !$planted, 'a step file planted under the new working directory is not allowed';
    ok $shipped,  'and the shipped Payment step still is';
};

# On a case-insensitive filesystem a file test accepts PAYMENT.pm for
# Payment.pm. Loading such a name could not run injected code, but the check is
# meant to name shipped classes exactly. (This filesystem is case-sensitive, so
# this subtest guards the rule rather than reproducing the bug.)
subtest 'a class name matches its file name exactly' => sub {
    ok !Registry::WorkflowStepClasses::is_allowed($_), "$_ is refused"
      for qw(
      Registry::DAO::WorkflowSteps::PAYMENT
      Registry::DAO::WorkflowSteps::PayMent
      Registry::DAO::WorkflowSteps::AttendanceCheck::upcomingEventProcessor
    );
};

# ----------------------------------------------------------------------------
# The creation paths, on a real database.
# ----------------------------------------------------------------------------
use Mojo::Home;
use Registry::DAO;
use Test::Registry::DB;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $creation = Registry::DAO::Workflow->from_yaml( $dao,
    Mojo::Home->new->child('workflows/workflow-creation.yml')->slurp );

# Walk the real workflow-creation workflow to its CreateWorkflow step with the
# given submission, the way a tenant's staff member would.
sub create_through_the_workflow ($submission) {
    my $run = $creation->new_run($db);
    $run->process( $db, $run->next_step($db), {} );
    $run->process( $db, $run->next_step($db), $submission );
    return $run->process( $db, $run->next_step($db), {} );
}

sub steps_with_class ($class) {
    $db->select( 'workflow_steps', 'count(*)', { class => $class } )->array->[0];
}

sub workflow_exists ($slug) {
    $db->select( 'workflows', 'count(*)', { slug => $slug } )->array->[0];
}

subtest 'workflow-creation naming a refused class is refused and stores nothing' => sub {
    my $ok = eval {
        create_through_the_workflow(
            {
                name        => 'Socket',
                slug        => 'socket-workflow',
                description => 'names a class that is not a step',
                steps       => [
                    { slug => 'only', description => 'x', class => 'IO::Socket::INET' },
                ],
            }
        );
        1;
    };
    ok !$ok, 'the submission is refused';
    like $@, qr/not an allowed workflow step class/, 'with a reason';
    is workflow_exists('socket-workflow'), 0, 'no workflow was stored';
    is steps_with_class('IO::Socket::INET'), 0, 'no step naming the class was stored';
};

subtest 'from_yaml naming a refused class dies and stores nothing' => sub {
    my $yaml = <<~'YAML';
        name: Planted
        slug: planted-yaml
        description: a YAML workflow naming a class outside the allowlist
        steps:
          - slug: first
            description: fine
            class: Registry::DAO::WorkflowStep
          - slug: second
            description: not fine
            class: IO::Socket::INET
        YAML
    my $ok = eval { Registry::DAO::Workflow->from_yaml( $dao, $yaml ); 1 };
    ok !$ok, 'the import dies';
    like $@, qr/not an allowed workflow step class/, 'with a reason';
    is workflow_exists('planted-yaml'), 0, 'no workflow was stored';
    is steps_with_class('IO::Socket::INET'), 0, 'no step naming the class was stored';
};

subtest 'a refused last step leaves no workflow and no earlier steps' => sub {
    my $ok = eval {
        create_through_the_workflow(
            {
                name        => 'Three',
                slug        => 'three-steps',
                description => 'only the third step is refused',
                steps       => [
                    { slug => 'one',   description => 'x', class => 'Registry::DAO::WorkflowStep' },
                    { slug => 'two',   description => 'x', class => 'Registry::DAO::WorkflowStep' },
                    { slug => 'three', description => 'x', class => 'IO::Socket::INET' },
                ],
            }
        );
        1;
    };
    ok !$ok, 'the submission is refused';
    is workflow_exists('three-steps'), 0, 'no workflow was stored';
    is $db->select( 'workflow_steps', 'count(*)', { slug => [qw(one two three)] } )->array->[0],
      0, 'and neither of the allowed earlier steps was left behind';
};

subtest 'updating a stored step to a refused class is refused and leaves it unchanged' => sub {
    my $step = $creation->first_step($db);
    my $before = $step->class;
    my $ok = eval { $step->update( $db, { class => 'IO::Socket::INET' } ); 1 };
    ok !$ok, 'the update is refused';
    like $@, qr/not an allowed workflow step class/, 'with a reason';
    my ($reread) = Registry::DAO::WorkflowStep->find( $db, { id => $step->id } );
    is $reread->class, $before, 'the stored class is unchanged';
};

# ----------------------------------------------------------------------------
# Load time. Rows already stored -- before the creation check existed, or
# written by anything that bypasses the DAO -- are not trusted either.
# ----------------------------------------------------------------------------

# Store a step row directly, as a bypass of the DAO would, and return its id.
sub plant_step ( $class, $conn = $db ) {
    state $n = 0;
    $n++;
    $conn->insert(
        'workflow_steps',
        {
            workflow_id => $creation->id,
            slug        => "planted-$n",
            description => 'planted',
            class       => $class,
        },
        { returning => 'id' }
    )->hash->{id};
}

subtest 'find refuses a stored non-allowlisted class without loading it' => sub {
    delete $INC{'IO/Socket/INET.pm'};
    ok !$INC{'IO/Socket/INET.pm'}, 'IO::Socket::INET is not loaded beforehand';

    my $id = plant_step('IO::Socket::INET');
    my $ok = eval { Registry::DAO::WorkflowStep->find( $db, { id => $id } ); 1 };
    ok !$ok, 'find dies';
    like $@, qr/not an allowed workflow step class/, 'saying the class is not allowed';
    ok !$INC{'IO/Socket/INET.pm'}, 'and the class was never required';
};

subtest 'find refuses a stored class carrying perl source without running it' => sub {
    no warnings 'once';
    undef $main::PWNED;
    my $id = plant_step('Registry::DAO::WorkflowStep; $main::PWNED = 1');
    my $ok = eval { Registry::DAO::WorkflowStep->find( $db, { id => $id } ); 1 };
    ok !$ok, 'find dies';
    like $@, qr/not an allowed workflow step class/, 'saying the class is not allowed';
    ok !defined $main::PWNED, 'and the source in the class column never ran';
};

subtest 'find still loads a shipped step class' => sub {
    for my $shipped (
        qw(
        Registry::DAO::WorkflowStep
        Registry::DAO::WorkflowSteps::Payment
        Registry::DAO::WorkflowSteps::AttendanceCheck::UpcomingEventProcessor
        )
      )
    {
        my $id   = plant_step($shipped);
        my $step = Registry::DAO::WorkflowStep->find( $db, { id => $id } );
        is ref $step, $shipped, "$shipped is found and blessed into its class";
    }
};

subtest 'find refuses a stored class with a trailing newline' => sub {
    my $id = plant_step("Registry::DAO::WorkflowStep\n");
    my $ok = eval { Registry::DAO::WorkflowStep->find( $db, { id => $id } ); 1 };
    ok !$ok, 'find dies';
    like $@, qr/not an allowed workflow step class/, 'saying the class is not allowed';
};

# The name check and the isa check are separate defences. If the name check
# were ever wrong -- a non-step helper module living in WorkflowSteps/, say --
# the isa check must still stop a non-step class before its constructor runs.
subtest 'find refuses a loaded class that is not a workflow step before its constructor' => sub {
    require IO::Handle;
    my $constructed = 0;
    no warnings 'redefine';
    local *IO::Handle::new = sub { $constructed++; bless {}, shift };
    local *Registry::WorkflowStepClasses::is_allowed = sub { 1 };

    my $id = plant_step('IO::Handle');
    my $ok = eval { Registry::DAO::WorkflowStep->find( $db, { id => $id } ); 1 };
    ok !$ok, 'find dies';
    like $@, qr/IO::Handle is not a workflow step/, 'saying it is not a step';
    is $constructed, 0, 'and IO::Handle->new was never called';
};

# A tenant's schema holds its own copy of workflow_steps. Rows there are no
# more trusted than rows in registry: the check is at load, on any connection.
subtest 'find refuses a non-allowlisted class planted in a tenant schema' => sub {
    require Test::Registry::Fixtures;
    Test::Registry::Fixtures::create_tenant( $db,
        { name => 'Allowlist Tenant', slug => 'allowlist_tenant' } );
    my $tenant_db = Registry::DAO->new( url => $test_db->uri, schema => 'allowlist_tenant' )->db;

    my $workflow = Registry::DAO::Workflow->create( $tenant_db,
        { slug => 'tenant-wf', name => 'Tenant WF', description => 'x' } );
    my $id = $tenant_db->insert(
        'workflow_steps',
        {
            workflow_id => $workflow->id,
            slug        => 'planted',
            description => 'planted in the tenant schema',
            class       => 'IO::Socket::INET',
        },
        { returning => 'id' }
    )->hash->{id};

    my $ok = eval { Registry::DAO::WorkflowStep->find( $tenant_db, { id => $id } ); 1 };
    ok !$ok, 'find on the tenant connection dies';
    like $@, qr/not an allowed workflow step class/, 'saying the class is not allowed';
};

subtest 'a workflow whose first step is refused cannot be started' => sub {
    require Registry::Utility::WorkflowProcessor;
    my $workflow = Registry::DAO::Workflow->create( $db,
        { slug => 'refused-first', name => 'Refused First', description => 'x' } );
    my $id = $db->insert(
        'workflow_steps',
        {
            workflow_id => $workflow->id,
            slug        => 'first',
            description => 'refused',
            class       => 'IO::Socket::INET',
        },
        { returning => 'id' }
    )->hash->{id};
    $db->update( 'workflows', { first_step => 'first' }, { id => $workflow->id } );
    ($workflow) = Registry::DAO::Workflow->find( $db, { id => $workflow->id } );

    my $ok = eval {
        Registry::WorkflowProcessor->new( dao => $dao )->new_run( $workflow, {} );
        1;
    };
    ok !$ok, 'starting the workflow dies';
    is $db->select( 'workflow_runs', 'count(*)', { workflow_id => $workflow->id } )->array->[0],
      0, 'and no run was left behind for it';
};

# The same through HTTP, which is how a visitor starts a workflow. The
# controller's start path has a fallback that builds a run by hand when
# new_run dies; a refused step class must not be papered over by it.
subtest 'starting a workflow over HTTP whose first step is refused leaves no run' => sub {
    require Test::Registry::Mojo;
    local $ENV{DB_URL} = $test_db->uri;

    my $workflow = Registry::DAO::Workflow->create( $db,
        { slug => 'refused-over-http', name => 'Refused Over HTTP', description => 'x' } );
    my $step_id = $db->insert(
        'workflow_steps',
        {
            workflow_id => $workflow->id,
            slug        => 'first',
            description => 'refused',
            class       => 'IO::Socket::INET',
        },
        { returning => 'id' }
    )->hash->{id};
    $db->update( 'workflows', { first_step => 'first' }, { id => $workflow->id } );

    my $t = Test::Registry::Mojo->new('Registry');
    $t->post_ok( '/refused-over-http' => form => {} );
    isnt $t->tx->res->code, 200, 'the start is not reported as a success';
    is $db->select( 'workflow_runs', 'count(*)', { workflow_id => $workflow->id } )->array->[0],
      0, 'and no run exists for the workflow, let alone one pointing at the refused step';
};

done_testing;
