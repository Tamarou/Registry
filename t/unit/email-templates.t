# ABOUTME: Unit tests for Registry::Email::Template
# ABOUTME: Tests rendering, HTML escaping, and graceful handling of missing variables
use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok subtest like unlike )];
defer { done_testing };

use Registry::Email::Template;

subtest 'render method exists' => sub {
    ok(Registry::Email::Template->can('render'), 'Template module has render method');
};

subtest 'render returns html and text keys' => sub {
    my $result = Registry::Email::Template->render('enrollment_confirmation',
        name       => 'Jane Doe',
        event      => 'Summer Camp',
        start_date => '2026-06-01',
        location   => 'City Park',
    );
    ok($result, 'render returns a value');
    ok(ref($result) eq 'HASH', 'render returns a hashref');
    ok(exists $result->{html}, 'result has html key');
    ok(exists $result->{text}, 'result has text key');
};

subtest 'HTML output contains expected sections' => sub {
    my $result = Registry::Email::Template->render('enrollment_confirmation',
        name       => 'Jane Doe',
        event      => 'Summer Camp',
        start_date => '2026-06-01',
        location   => 'City Park',
    );
    my $html = $result->{html};
    like($html, qr/<html/i,     'HTML contains html tag');
    like($html, qr/Registry/,   'HTML contains Registry branding in header');
    like($html, qr/Jane Doe/,   'HTML contains recipient name');
    like($html, qr/Summer Camp/,'HTML contains event name');
    like($html, qr/<\/html>/i,  'HTML contains closing html tag');
};

subtest 'text output is plain text without HTML tags' => sub {
    my $result = Registry::Email::Template->render('enrollment_confirmation',
        name       => 'Jane Doe',
        event      => 'Summer Camp',
        start_date => '2026-06-01',
        location   => 'City Park',
    );
    my $text = $result->{text};
    unlike($text, qr/<html/i, 'Text does not contain html tags');
    like($text, qr/Jane Doe/,  'Text contains recipient name');
    like($text, qr/Summer Camp/, 'Text contains event name');
};

subtest 'waitlist_offer template renders' => sub {
    my $result = Registry::Email::Template->render('waitlist_offer',
        name       => 'Bob Smith',
        event      => 'Fall Program',
        deadline   => '2026-09-01',
    );
    ok($result, 'waitlist_offer renders');
    like($result->{html}, qr/Bob Smith/, 'contains name');
    like($result->{html}, qr/Fall Program/, 'contains event name');
    like($result->{text}, qr/Bob Smith/, 'text contains name');
};

subtest 'attendance_alert template renders' => sub {
    my $result = Registry::Email::Template->render('attendance_alert',
        name       => 'Alice Teacher',
        event      => 'Monday Class',
        start_time => '9:00 AM',
        location   => 'Room 101',
    );
    ok($result, 'attendance_alert renders');
    like($result->{html}, qr/Alice Teacher/, 'contains name');
    like($result->{html}, qr/Monday Class/, 'contains event name');
};

subtest 'message_notification template renders' => sub {
    my $result = Registry::Email::Template->render('message_notification',
        name    => 'Parent User',
        subject => 'Important Update',
        body    => 'Please read this message.',
    );
    ok($result, 'message_notification renders');
    like($result->{html}, qr/Parent User/, 'contains name');
    like($result->{html}, qr/Important Update/, 'contains subject');
};

subtest 'user content is HTML-escaped' => sub {
    my $xss_payload = '<script>alert("xss")</script>';
    my $result = Registry::Email::Template->render('enrollment_confirmation',
        name       => $xss_payload,
        event      => 'Test Event',
        start_date => '2026-06-01',
        location   => 'Test Location',
    );
    my $html = $result->{html};
    unlike($html, qr/<script>/,         'script tag is escaped in HTML');
    like($html,   qr/&lt;script&gt;/,  'angle brackets are HTML-escaped');
};

subtest 'missing variables produce graceful fallback (no crash)' => sub {
    my $result;
    eval {
        $result = Registry::Email::Template->render('enrollment_confirmation');
    };
    ok(!$@, 'render does not crash with no variables') or diag("Error: $@");
    ok($result, 'render returns something even with no variables');
    ok(exists $result->{html}, 'result still has html key');
    ok(exists $result->{text}, 'result still has text key');
};

subtest 'missing template produces graceful fallback (no crash)' => sub {
    my $result;
    eval {
        $result = Registry::Email::Template->render('nonexistent_template',
            name => 'Test User',
        );
    };
    ok(!$@, 'render does not crash with unknown template') or diag("Error: $@");
    ok($result, 'render returns something for unknown template');
};

subtest 'HTML has inline CSS styles (no external stylesheets)' => sub {
    my $result = Registry::Email::Template->render('enrollment_confirmation',
        name       => 'Test User',
        event      => 'Test Event',
        start_date => '2026-06-01',
        location   => 'Test Location',
    );
    my $html = $result->{html};
    unlike($html, qr/<link[^>]*rel=["']stylesheet["']/i, 'no external stylesheet links');
    like($html, qr/style=["']/i, 'uses inline CSS styles');
};
