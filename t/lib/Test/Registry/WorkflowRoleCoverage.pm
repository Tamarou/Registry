# ABOUTME: Test helper: which workflow files in a directory are neither role-guarded nor marked public.
# ABOUTME: Used by t/security/workflow-roles-cover-every-workflow.t on the real workflows and on fixtures.
use 5.42.0;

package Test::Registry::WorkflowRoleCoverage;

use builtin qw(is_bool);
no warnings 'experimental::builtin';
use Mojo::File qw(path);
use YAML::XS qw(Load);

# Returns one line per problem, each naming the file and (where it has one)
# the slug. $roles is a code ref: slug -> the workflow_roles entry or undef.
sub problems ( $dir, $roles ) {
    my @problems;
    for my $file ( path($dir)->list->grep(qr/\.ya?ml\z/)->sort->each ) {
        my $name = $file->basename;

        my $data = eval { Load( $file->slurp ) };
        if ( !$data || ref $data ne 'HASH' ) {
            push @problems, "$name does not parse as a workflow: " . ( $@ || 'not a mapping' );
            next;
        }

        # Exactly what import_workflows skips.
        next if $data->{draft};

        # The slug from_yaml would store, not the file name.
        my $slug = $data->{slug} // lc( ( $data->{name} // '' ) =~ s/\s+/-/gr );

        # Only a YAML boolean true is the mark: not 1, not "true", not yes.
        my $public = is_bool( $data->{public} ) && $data->{public};
        my $guarded = defined $roles->($slug);

        if ( $guarded && $public ) {
            push @problems,
              "$name ($slug) has a workflow_roles entry and the public mark, which contradict each other";
        }
        elsif ( !$guarded && !$public ) {
            push @problems, "$name ($slug) has no workflow_roles entry and no public mark";
        }
    }
    return @problems;
}

1;
