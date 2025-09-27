use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like unlike is_deeply subtest use_ok isa_ok can_ok )];
defer { done_testing };

# ABOUTME: Tests for style.css - validates utility classes, page-specific styles, and HTMX functionality
# ABOUTME: Ensures style.css imports structure.css and provides backward compatibility with legacy utility classes

# Test that style.css file exists and is properly structured
subtest 'style CSS file structure' => sub {
    my $css_file = '/home/perigrin/dev/Registry/public/css/style.css';
    ok(-f $css_file, 'style.css file exists');

    my $css_content = do {
        local $/;
        open my $fh, '<', $css_file or die "Cannot read $css_file: $!";
        <$fh>;
    };
    ok(length($css_content) > 0, 'style.css has content');

    # Check for proper file header comments
    like($css_content, qr/ABOUTME:.*style.*CSS/i, 'File has proper ABOUTME header describing style CSS');
    like($css_content, qr/ABOUTME:.*utility.*classes/i, 'File explains utility classes approach');
};

subtest 'imports structure.css for design tokens' => sub {
    my $css_file = '/home/perigrin/dev/Registry/public/css/style.css';
    my $css_content = do {
        local $/;
        open my $fh, '<', $css_file or die "Cannot read $css_file: $!";
        <$fh>;
    };

    # Check that style.css imports structure.css
    like($css_content, qr/\@import\s+.*structure\.css/, 'style.css imports structure.css');

    # Check that import is at the top of the file (before other CSS rules)
    my @lines = split /\n/, $css_content;
    my $import_line;
    my $first_rule_line;

    for my $i (0..$#lines) {
        if ($lines[$i] =~ /\@import.*structure\.css/ && !defined $import_line) {
            $import_line = $i;
        }
        if ($lines[$i] =~ /^\s*[^\/\*\@].*\{/ && !defined $first_rule_line) {
            $first_rule_line = $i;
        }
    }

    ok(defined $import_line, '@import statement found');
    if (defined $import_line && defined $first_rule_line) {
        ok($import_line < $first_rule_line, '@import appears before CSS rules');
    }
};

subtest 'legacy utility classes for backward compatibility' => sub {
    my $css_file = '/home/perigrin/dev/Registry/public/css/style.css';
    my $css_content = do {
        local $/;
        open my $fh, '<', $css_file or die "Cannot read $css_file: $!";
        <$fh>;
    };

    # Check for essential utility classes
    like($css_content, qr/\.btn\s*\{/, 'Legacy .btn class defined');
    like($css_content, qr/\.card\s*\{/, 'Legacy .card class defined');
    like($css_content, qr/\.container\s*\{/, 'Legacy .container class defined');
    like($css_content, qr/\.row\s*\{/, 'Legacy .row class defined');
    like($css_content, qr/\.col\s*\{/, 'Legacy .col class defined');

    # Check button variants
    like($css_content, qr/\.btn-primary\s*\{/, 'Legacy .btn-primary class defined');
    like($css_content, qr/\.btn-secondary\s*\{/, 'Legacy .btn-secondary class defined');
    like($css_content, qr/\.btn-success\s*\{/, 'Legacy .btn-success class defined');
    like($css_content, qr/\.btn-danger\s*\{/, 'Legacy .btn-danger class defined');

    # Check that legacy classes use design tokens from structure.css
    like($css_content, qr/color:\s*var\(--color-/, 'Legacy classes use color design tokens');
    like($css_content, qr/background-color:\s*var\(--color-/, 'Legacy classes use background color tokens');
    like($css_content, qr/padding:\s*var\(--space-/, 'Legacy classes use spacing tokens');
};

subtest 'HTMX indicator classes and dynamic states' => sub {
    my $css_file = '/home/perigrin/dev/Registry/public/css/style.css';
    my $css_content = do {
        local $/;
        open my $fh, '<', $css_file or die "Cannot read $css_file: $!";
        <$fh>;
    };

    # Check that critical HTMX classes are preserved
    like($css_content, qr/\.htmx-indicator\s*\{/, 'htmx-indicator class preserved');
    like($css_content, qr/\.htmx-request/, 'htmx-request class preserved');

    # Check utility classes for dynamic states
    like($css_content, qr/\.hidden\s*\{/, 'hidden utility class preserved');
    like($css_content, qr/\.loading\s*\{/, 'loading utility class preserved');
    like($css_content, qr/\.spinner\s*\{/, 'spinner utility class preserved');

    # Check validation state classes
    like($css_content, qr/\.error\s*\{/, 'error state class preserved');
    like($css_content, qr/\.success\s*\{/, 'success state class preserved');

    # Check that these classes work with semantic elements
    like($css_content, qr/input\.error/, 'error class works with input elements');
    like($css_content, qr/textarea\.error/, 'error class works with textarea elements');
};

subtest 'page-specific styles' => sub {
    my $css_file = '/home/perigrin/dev/Registry/public/css/style.css';
    my $css_content = do {
        local $/;
        open my $fh, '<', $css_file or die "Cannot read $css_file: $!";
        <$fh>;
    };

    # Check for marketing page styles
    like($css_content, qr/\.marketing/, 'Marketing page styles defined');
    like($css_content, qr/\.hero/, 'Hero section styles defined');
    like($css_content, qr/\.features/, 'Features section styles defined');

    # Check for tenant signup styles
    like($css_content, qr/\.tenant-signup/, 'Tenant signup styles defined');
    like($css_content, qr/\.profile/, 'Profile styles defined');

    # Check for specialized components
    like($css_content, qr/\.notification/, 'Notification component styles defined');
    like($css_content, qr/\.modal/, 'Modal component styles defined');
};

subtest 'no design token definitions (imports only)' => sub {
    my $css_file = '/home/perigrin/dev/Registry/public/css/style.css';
    my $css_content = do {
        local $/;
        open my $fh, '<', $css_file or die "Cannot read $css_file: $!";
        <$fh>;
    };

    # Check that no CSS custom properties are defined (should import from structure.css)
    my @token_definitions = $css_content =~ /(--[\w-]+):\s*([^;]+);/g;
    is(scalar(@token_definitions), 0, 'No design token definitions in style.css (should import from structure.css)');

    # But check that design tokens are used
    my $token_usage = () = $css_content =~ /var\(--[\w-]+\)/g;
    ok($token_usage > 10, 'Style.css uses design tokens from structure.css (found ' . $token_usage . ' usages)');
};

subtest 'CSS validation and syntax' => sub {
    my $css_file = '/home/perigrin/dev/Registry/public/css/style.css';
    my $css_content = do {
        local $/;
        open my $fh, '<', $css_file or die "Cannot read $css_file: $!";
        <$fh>;
    };

    # Basic CSS syntax validation
    my $open_braces = () = $css_content =~ /\{/g;
    my $close_braces = () = $css_content =~ /\}/g;
    is($open_braces, $close_braces, 'CSS has balanced braces');

    # Check for common CSS syntax errors
    unlike($css_content, qr/;;\s*/, 'No double semicolons');
    unlike($css_content, qr/\{\s*\}/, 'No empty CSS rules');

    # Check that @import is valid
    unlike($css_content, qr/\@import.*["'].*["']\s*;.*\@import/s, 'No @import statements after CSS rules');
};

subtest 'backward compatibility validation' => sub {
    my $css_file = '/home/perigrin/dev/Registry/public/css/style.css';
    my $css_content = do {
        local $/;
        open my $fh, '<', $css_file or die "Cannot read $css_file: $!";
        <$fh>;
    };

    # Ensure critical classes that might be in templates still exist
    like($css_content, qr/\.btn/, 'Button utility classes preserved');
    like($css_content, qr/\.text-/, 'Text utility classes preserved');
    like($css_content, qr/\.bg-/, 'Background utility classes preserved');
    like($css_content, qr/\.p-\d/, 'Padding utility classes preserved');
    like($css_content, qr/\.m-\d/, 'Margin utility classes preserved');

    # Check responsive utilities
    like($css_content, qr/\.d-/, 'Display utility classes preserved');
    like($css_content, qr/\.flex/, 'Flexbox utility classes preserved');
};