# ABOUTME: Tests for tenant signup workflow branding fixes (issues #125 and #135).
# ABOUTME: Verifies template content for correct titles and support email addresses.

use 5.42.0;
use Test::More import => [qw( done_testing ok like unlike subtest )];
use experimental qw(defer);

defer { done_testing };

my $users_template  = do { local $/; open my $fh, '<', 'templates/tenant-signup/users.html.ep' or die $!; <$fh> };
my $review_template = do { local $/; open my $fh, '<', 'templates/tenant-signup/review.html.ep' or die $!; <$fh> };

subtest 'users.html.ep sets a page title (issue #125)' => sub {
    like(
        $users_template,
        qr/\%\s*title\s+['"]Team Setup['"]/,
        'users.html.ep sets title to "Team Setup"'
    );
};

subtest 'review.html.ep uses TinyArtEmpire support email (issue #135)' => sub {
    unlike(
        $review_template,
        qr/support\@registry\.com/,
        'review.html.ep does not contain support@registry.com'
    );
    like(
        $review_template,
        qr/support\@tinyartempire\.com/,
        'review.html.ep contains support@tinyartempire.com'
    );
};
