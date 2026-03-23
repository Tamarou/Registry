# ABOUTME: Tests for JavaScript fixes in layout templates and workflow-progress component.
# ABOUTME: Covers issue #128 (dark mode localStorage persistence) and #131 (custom element guard).

use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok like unlike pass )];
defer { done_testing };

use Mojo::File qw(path);

my $workflow_layout  = path('templates/layouts/workflow.html.ep');
my $default_layout   = path('templates/layouts/default.html.ep');
my $teacher_layout   = path('templates/layouts/teacher.html.ep');
my $progress_js      = path('public/js/components/workflow-progress.js');

# ---------------------------------------------------------------------------
# Issue #128: Dark mode preference persists via localStorage
# ---------------------------------------------------------------------------

{
    my $content = $workflow_layout->slurp;

    like(
        $content,
        qr/localStorage\.setItem\s*\(\s*['"]theme['"]/,
        'workflow layout: toggleTheme saves preference to localStorage'
    );

    like(
        $content,
        qr/localStorage\.getItem\s*\(\s*['"]theme['"]/,
        'workflow layout: page load reads saved theme from localStorage'
    );
}

{
    my $content = $default_layout->slurp;

    like(
        $content,
        qr/localStorage\.setItem\s*\(\s*['"]theme['"]/,
        'default layout: toggleTheme saves preference to localStorage'
    );

    like(
        $content,
        qr/localStorage\.getItem\s*\(\s*['"]theme['"]/,
        'default layout: page load reads saved theme from localStorage'
    );
}

{
    my $content = $teacher_layout->slurp;

    like(
        $content,
        qr/localStorage\.setItem\s*\(\s*['"]theme['"]/,
        'teacher layout: toggleTheme saves preference to localStorage'
    );

    like(
        $content,
        qr/localStorage\.getItem\s*\(\s*['"]theme['"]/,
        'teacher layout: page load reads saved theme from localStorage'
    );
}

# ---------------------------------------------------------------------------
# Issue #131: WorkflowProgress custom element re-registration guard
# ---------------------------------------------------------------------------

{
    my $content = $progress_js->slurp;

    like(
        $content,
        qr/if\s*\(\s*!customElements\.get\s*\(\s*['"]workflow-progress['"]\s*\)\s*\)/,
        'workflow-progress.js: registration is wrapped in customElements.get guard'
    );

    # The guard must appear BEFORE the class definition (not after)
    my $guard_pos = index($content, "if (!customElements.get('workflow-progress'))");
    my $class_pos = index($content, 'class WorkflowProgress');

    ok(
        $guard_pos != -1 && $class_pos != -1 && $guard_pos < $class_pos,
        'workflow-progress.js: customElements.get guard appears before class definition'
    );
}
