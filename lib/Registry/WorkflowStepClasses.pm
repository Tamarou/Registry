# ABOUTME: The server-side allowlist of workflow step classes: the shipped ones and nothing else.
# ABOUTME: A tenant composes allowed steps; a class name from a form or a row is checked here first.
use 5.42.0;

package Registry::WorkflowStepClasses;

use File::Basename qw(dirname);
use File::Find ();
use File::Spec;

# The application's own lib/Registry/DAO/WorkflowSteps, found from this file's
# location rather than from @INC: @INC includes t/lib under test and could
# include anything in production, and a step file placed on it must not become
# allowed. Made absolute once, here: __FILE__ is relative when lib/ is loaded
# through a relative `use lib`, and a relative directory would follow the
# process's working directory.
my $STEPS_DIR = File::Spec->rel2abs(
    File::Spec->catdir( dirname(__FILE__), 'DAO', 'WorkflowSteps' ) );

# The exact class names the shipped tree holds, read once at load. Comparing
# against names taken from the directory, rather than testing a file path,
# keeps the match exact on a case-insensitive filesystem too.
my %SHIPPED = ( 'Registry::DAO::WorkflowStep' => 1 );
File::Find::find(
    {
        no_chdir => 1,
        wanted   => sub {
            return unless /\.pm\z/ && -f $_;
            my $relative = File::Spec->abs2rel( $_, $STEPS_DIR );
            my $class    = join '::', 'Registry::DAO::WorkflowSteps',
              File::Spec->splitdir( $relative =~ s/\.pm\z//r );
            $SHIPPED{$class} = 1;
        },
    },
    $STEPS_DIR
);

sub is_allowed ($class) {
    return 0 unless defined $class;

    # \A and \z, not ^ and $: `$` matches before a trailing newline, and a
    # name with one is not the class it looks like.
    return 0
      unless $class eq 'Registry::DAO::WorkflowStep'
      || $class =~
      /\ARegistry::DAO::WorkflowSteps::[A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)*\z/;

    return $SHIPPED{$class} ? 1 : 0;
}

1;
