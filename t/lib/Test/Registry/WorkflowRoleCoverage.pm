# ABOUTME: Test helper: which workflow files in a directory imported to a row with neither roles nor the public mark.
# ABOUTME: Used by t/security/workflow-roles-cover-every-workflow.t on the real workflows and on fixtures.
use 5.42.0;

package Test::Registry::WorkflowRoleCoverage;

use Mojo::File qw(path);
use YAML::XS qw(Load);

# Walks the directory with list_tree, as the importers do, so a workflow in a
# subdirectory is checked too. Returns one line per problem, each naming the file and (where it has one)
# the slug. $entry is a code ref: slug -> the stored row ({ roles, public }) or undef.
sub problems ( $dir, $entry ) {
    my @problems;
    for my $file ( path($dir)->list_tree->grep(qr/\.ya?ml\z/)->sort->each ) {
        my $name = $file->to_rel($dir)->to_string;

        my $data = eval { Load( $file->slurp ) };
        if ( !$data || ref $data ne 'HASH' ) {
            push @problems, "$name does not parse as a workflow: " . ( $@ || 'not a mapping' );
            next;
        }

        # Exactly what import_workflows skips.
        next if $data->{draft};

        # The slug from_yaml would store, not the file name.
        my $slug = $data->{slug} // lc( ( $data->{name} // '' ) =~ s/\s+/-/gr );

        my $row = $entry->($slug);
        if ( !$row ) {
            push @problems, "$name ($slug) has no stored workflow row";
            next;
        }

        my $guarded = $row->{roles} && @{ $row->{roles} };
        if ( $guarded && $row->{public} ) {
            push @problems, "$name ($slug) has roles and the public mark, which contradict each other";
        }
        elsif ( !$guarded && !$row->{public} ) {
            push @problems, "$name ($slug) has no roles and no public mark";
        }
    }
    return @problems;
}

1;
