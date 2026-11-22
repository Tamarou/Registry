# ABOUTME: The server-side allowlist of workflow step classes: the shipped ones and nothing else.
# ABOUTME: A tenant composes allowed steps; a class name from a form or a row is checked here first.
use 5.42.0;

package Registry::WorkflowStepClasses;

use File::Basename qw(dirname);
use File::Spec;

# The application's own lib/Registry/DAO/WorkflowSteps, found from this file's
# location rather than from @INC: @INC includes t/lib under test and could
# include anything in production, and a step file placed on it must not become
# allowed.
my $STEPS_DIR =
  File::Spec->catdir( dirname(__FILE__), 'DAO', 'WorkflowSteps' );

sub is_allowed ($class) {
    return 0 unless defined $class;
    return 1 if $class eq 'Registry::DAO::WorkflowStep';

    # \A and \z, not ^ and $: `$` matches before a trailing newline, and a
    # name with one is not the class it looks like.
    my ($rest) = $class =~
      /\ARegistry::DAO::WorkflowSteps::([A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)*)\z/
      or return 0;
    my $file = File::Spec->catfile( $STEPS_DIR, split /::/, "$rest.pm" );
    return -f $file ? 1 : 0;
}

1;
