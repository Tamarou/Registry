use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like unlike is_deeply subtest use_ok isa_ok can_ok )];
defer { done_testing };

# ABOUTME: Tests for structure.css - validates design tokens and semantic HTML styling architecture
# ABOUTME: Ensures structure.css contains design tokens, semantic element styles, and component patterns using data attributes

# Test that structure.css file exists and is properly structured
subtest 'structure CSS file structure' => sub {
    my $css_file = 'public/css/structure.css';
    ok(-f $css_file, 'structure.css file exists');

    my $css_content = do {
        local $/;
        open my $fh, '<', $css_file or die "Cannot read $css_file: $!";
        <$fh>;
    };
    ok(length($css_content) > 0, 'structure.css has content');

    # Check for proper file header comments
    like($css_content, qr/ABOUTME:.*structure.*CSS/i, 'File has proper ABOUTME header describing structure CSS');
    like($css_content, qr/ABOUTME:.*design.*tokens/i, 'File explains design tokens approach');
};

subtest 'design tokens centralization' => sub {
    my $css_file = 'public/css/structure.css';
    my $css_content = do {
        local $/;
        open my $fh, '<', $css_file or die "Cannot read $css_file: $!";
        <$fh>;
    };

    # Check that all essential design tokens are defined
    like($css_content, qr/--color-primary:\s*#BF349A/, 'Primary magenta color defined');
    like($css_content, qr/--color-primary-dark:\s*#8C2771/, 'Primary dark purple defined');
    like($css_content, qr/--color-secondary:\s*#2ABFBF/, 'Secondary cyan color defined');
    like($css_content, qr/--color-gray-50:\s*#E7DCF2/, 'Light lavender background defined');

    # Check typography tokens
    like($css_content, qr/--font-family:/, 'Font family design token defined');
    like($css_content, qr/--font-size-base:/, 'Base font size token defined');
    like($css_content, qr/--line-height-normal:/, 'Line height token defined');

    # Check spacing tokens
    like($css_content, qr/--space-\d+:/, 'Spacing design tokens defined');
    like($css_content, qr/--radius-\w+:/, 'Border radius design tokens defined');
};

subtest 'semantic typography styles' => sub {
    my $css_file = 'public/css/structure.css';
    my $css_content = do {
        local $/;
        open my $fh, '<', $css_file or die "Cannot read $css_file: $!";
        <$fh>;
    };

    # Check that all heading levels have styling
    for my $level (1..6) {
        like($css_content, qr/h$level\s*\{/, "h$level element has styles defined");
    }

    # Check paragraph and text element styles
    like($css_content, qr/p\s*\{/, 'Paragraph elements have styles');
    like($css_content, qr/a\s*\{/, 'Link elements have styles');
    like($css_content, qr/strong\s*\{/, 'Strong elements have styles');
    like($css_content, qr/em\s*\{/, 'Emphasis elements have styles');
    like($css_content, qr/small\s*\{/, 'Small elements have styles');

    # Check that font sizes use design tokens
    like($css_content, qr/font-size:\s*var\(--font-size-/, 'Typography uses font-size design tokens');
    like($css_content, qr/color:\s*var\(--color-text-/, 'Typography uses color design tokens');
};

subtest 'semantic form element styles' => sub {
    my $css_file = 'public/css/structure.css';
    my $css_content = do {
        local $/;
        open my $fh, '<', $css_file or die "Cannot read $css_file: $!";
        <$fh>;
    };

    # Check basic form elements
    like($css_content, qr/input\s*[,{]/, 'Input elements have base styles');
    like($css_content, qr/textarea\s*\{/, 'Textarea elements have styles');
    like($css_content, qr/select\s*\{/, 'Select elements have styles');
    like($css_content, qr/button\s*\{/, 'Button elements have styles');
    like($css_content, qr/label\s*\{/, 'Label elements have styles');

    # Check specific input types
    like($css_content, qr/input\[type=["\']text["\']/, 'Text input styling defined');
    like($css_content, qr/input\[type=["\']email["\']/, 'Email input styling defined');
    like($css_content, qr/input\[type=["\']tel["\']/, 'Tel input styling defined');

    # Check form focus states
    like($css_content, qr/input:focus/, 'Input focus states defined');
    like($css_content, qr/textarea:focus/, 'Textarea focus states defined');
    like($css_content, qr/select:focus/, 'Select focus states defined');

    # Check that form elements use design tokens
    like($css_content, qr/border:\s*.*var\(--/, 'Form elements use border design tokens');
    like($css_content, qr/border-radius:\s*var\(--radius-/, 'Form elements use radius design tokens');
    like($css_content, qr/padding:\s*var\(--space-/, 'Form elements use spacing design tokens');
};

subtest 'component architecture with data attributes' => sub {
    my $css_file = 'public/css/structure.css';
    my $css_content = do {
        local $/;
        open my $fh, '<', $css_file or die "Cannot read $css_file: $!";
        <$fh>;
    };

    # Check button variants via data attributes (classless approach)
    like($css_content, qr/button\[data-variant=["\']primary["\']/, 'Primary button variant with data attribute');
    like($css_content, qr/button\[data-variant=["\']secondary["\']/, 'Secondary button variant with data attribute');
    like($css_content, qr/button\[data-variant=["\']success["\']/, 'Success button variant with data attribute');
    like($css_content, qr/button\[data-variant=["\']danger["\']/, 'Danger button variant with data attribute');

    # Check button sizes via data attributes
    like($css_content, qr/button\[data-size=["\']sm["\']/, 'Small button size with data attribute');
    like($css_content, qr/button\[data-size=["\']lg["\']/, 'Large button size with data attribute');

    # Check button states
    like($css_content, qr/button:hover/, 'Button hover states defined');
    like($css_content, qr/button:focus/, 'Button focus states defined');
    like($css_content, qr/button:disabled/, 'Button disabled states defined');

    # Check that buttons use vaporwave colors
    like($css_content, qr/background-color:\s*var\(--color-primary\)/, 'Primary buttons use primary color');
    like($css_content, qr/background-color:\s*var\(--color-secondary\)/, 'Secondary buttons use secondary color');
};

subtest 'semantic layout elements' => sub {
    my $css_file = 'public/css/structure.css';
    my $css_content = do {
        local $/;
        open my $fh, '<', $css_file or die "Cannot read $css_file: $!";
        <$fh>;
    };

    # Check semantic layout elements
    like($css_content, qr/header\s*\{/, 'Header element styling defined');
    like($css_content, qr/main\s*\{/, 'Main element styling defined');
    like($css_content, qr/section\s*\{/, 'Section element styling defined');
    like($css_content, qr/article\s*\{/, 'Article element styling defined');
    like($css_content, qr/aside\s*\{/, 'Aside element styling defined');
    like($css_content, qr/footer\s*\{/, 'Footer element styling defined');

    # Check that layout uses design tokens
    like($css_content, qr/margin:\s*var\(--space-/, 'Layout uses spacing design tokens');
    like($css_content, qr/padding:\s*var\(--space-/, 'Layout uses padding design tokens');
};

subtest 'responsive design with semantic elements' => sub {
    my $css_file = 'public/css/structure.css';
    my $css_content = do {
        local $/;
        open my $fh, '<', $css_file or die "Cannot read $css_file: $!";
        <$fh>;
    };

    # Check that media queries are present
    like($css_content, qr/\@media.*max-width/, 'Responsive media queries defined');

    # Check that semantic elements scale properly
    like($css_content, qr/\@media.*?h1\s*\{.*?\}/s, 'H1 responsive scaling defined');
    like($css_content, qr/\@media.*?h2\s*\{.*?\}/s, 'H2 responsive scaling defined');

    # Check that form elements scale properly on mobile
    like($css_content, qr/\@media.*?input.*?\}/s, 'Input responsive scaling defined');
    like($css_content, qr/\@media.*?button.*?\}/s, 'Button responsive scaling defined');
};

subtest 'CSS validation and syntax' => sub {
    my $css_file = 'public/css/structure.css';
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

    # Check that selectors are valid (no leading dots on semantic elements)
    unlike($css_content, qr/\.h[1-6]\s*\{/, 'No class selectors for headings (should be semantic)');
    unlike($css_content, qr/\.p\s*\{/, 'No class selector for paragraphs (should be semantic)');
    unlike($css_content, qr/\.button\s*\{/, 'No class selector for buttons (should be semantic)');
};

subtest 'no duplication of design tokens' => sub {
    my $structure_css = do {
        local $/;
        open my $fh, '<', '/home/perigrin/dev/Registry/public/css/structure.css' or die "Cannot read structure.css: $!";
        <$fh>;
    };
    my $style_css = do {
        local $/;
        open my $fh, '<', '/home/perigrin/dev/Registry/public/css/style.css' or die "Cannot read style.css: $!";
        <$fh>;
    };

    # Extract design tokens from both files
    my @structure_tokens = $structure_css =~ /(--[\w-]+):\s*([^;]+);/g;
    my @style_tokens = $style_css =~ /(--[\w-]+):\s*([^;]+);/g;

    my %structure_vars;
    for (my $i = 0; $i < @structure_tokens; $i += 2) {
        $structure_vars{$structure_tokens[$i]} = $structure_tokens[$i + 1];
    }

    my %style_vars;
    for (my $i = 0; $i < @style_tokens; $i += 2) {
        $style_vars{$style_tokens[$i]} = $style_tokens[$i + 1];
    }

    # Check that design tokens are only in structure.css
    for my $token (keys %style_vars) {
        # Skip @import and other non-variable declarations
        next unless $token =~ /^--/;
        ok(!exists $structure_vars{$token}, "Design token $token not duplicated between files");
    }

    # Ensure structure.css has all the essential tokens
    ok(exists $structure_vars{'--color-primary'}, 'Primary color token in structure.css');
    ok(exists $structure_vars{'--font-family'}, 'Font family token in structure.css');
    ok(scalar(keys %structure_vars) > 10, 'Structure.css contains substantial design tokens');
};