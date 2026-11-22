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

done_testing;
