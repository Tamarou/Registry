# ABOUTME: Tests that no workflow templates or JS use hx-target="body" which causes step stacking.
# ABOUTME: Workflow step transitions should use standard form POST + redirect, not HTMX body swaps.
use 5.34.0;
use experimental 'signatures';
use Test::More;
use File::Find;
use Mojo::File qw(curfile);

my $root = curfile->dirname->dirname->dirname;

my @violations;
my @checked_files;

my @template_dirs = map { $root->child($_) } qw(
    templates/tenant-signup
    templates/summer-camp-registration
    templates/program-creation
    templates/program-creation-enhanced
    templates/pricing-plan-creation
);

for my $dir (@template_dirs) {
    next unless -d $dir;
    find(sub {
        return unless /\.html\.ep$/;
        push @checked_files, $File::Find::name;
        my $content = Mojo::File->new($File::Find::name)->slurp;
        if ($content =~ /hx-target=["']body["']/) {
            push @violations, $File::Find::name;
        }
    }, "$dir");
}

my $progress_js = $root->child('public/js/components/workflow-progress.js');
if (-f $progress_js) {
    push @checked_files, "$progress_js";
    my $content = $progress_js->slurp;
    if ($content =~ /target:\s*['"]body['"]/ || $content =~ /hx-target="body"/) {
        push @violations, "$progress_js";
    }
}

ok(@checked_files > 0, 'At least one file was scanned');
is(scalar @violations, 0, 'No workflow templates or JS use hx-target="body"')
    or diag "Files with body-targeting HTMX: " . join("\n  ", @violations);

done_testing;
