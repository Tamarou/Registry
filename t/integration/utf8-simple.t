#!/usr/bin/env perl
# ABOUTME: Simple test for UTF-8 character handling in templates
# ABOUTME: Focuses on template rendering without database complexity

use 5.40.2;
use utf8;
use Test::More;
use Test::Mojo;
use Mojo::File qw(path);

# Initialize test application
my $t = Test::Mojo->new('Registry');

# Test UTF-8 characters from various languages
my @test_strings = (
    'Café français',           # French
    'Größe über älteren',      # German
    'Niño español',            # Spanish
    '日本語テスト',             # Japanese
    '中文测试',                # Chinese
    'Тест кириллица',          # Russian
    'مرحبا بالعالم',           # Arabic
    'שלום עולם',              # Hebrew
    'Emoji test 😀🎉🌟',       # Emojis
);

subtest 'Simple template rendering with UTF-8' => sub {
    # Create a simple test template file
    my $template_dir = path('templates/test-utf8');
    $template_dir->make_path;

    my $template_file = $template_dir->child('simple.html.ep');
    my $content = <<'TEMPLATE';
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>UTF-8 Test</title>
</head>
<body>
    <h1>UTF-8 Character Test</h1>
    <p>French: Café français</p>
    <p>German: Größe über älteren</p>
    <p>Spanish: Niño español</p>
    <p>Japanese: 日本語テスト</p>
    <p>Chinese: 中文测试</p>
    <p>Russian: Тест кириллица</p>
    <p>Arabic: مرحبا بالعالم</p>
    <p>Hebrew: שלום עולם</p>
    <p>Emoji: 😀🎉🌟</p>
</body>
</html>
TEMPLATE

    # Write template with UTF-8 encoding
    $template_file->spew($content);

    # Add a test route
    $t->app->routes->get('/test-utf8-simple' => sub {
        my $c = shift;
        $c->render(template => 'test-utf8/simple');
    });

    # Test rendering the template
    $t->get_ok('/test-utf8-simple')
      ->status_is(200)
      ->content_type_like(qr/text\/html/);

    # Check that UTF-8 characters are properly displayed
    for my $test_string (@test_strings) {
        $t->content_like(qr/\Q$test_string\E/, "Template contains: $test_string");
    }

    # Cleanup
    $template_file->remove if -e $template_file;
    $template_dir->remove_tree if -d $template_dir;
};

subtest 'Dynamic UTF-8 content via stash' => sub {
    # Test passing UTF-8 data through stash

    my $template_dir = path('templates/test-utf8');
    $template_dir->make_path;

    my $template_file = $template_dir->child('dynamic.html.ep');
    my $content = <<'TEMPLATE';
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title><%= $title %></title>
</head>
<body>
    <h1><%= $heading %></h1>
    <p><%= $message %></p>
    <ul>
    % for my $item (@$items) {
        <li><%= $item %></li>
    % }
    </ul>
</body>
</html>
TEMPLATE

    $template_file->spew($content);

    # Add test route with UTF-8 data
    $t->app->routes->get('/test-utf8-dynamic' => sub {
        my $c = shift;
        $c->stash(
            title   => 'Página de Prueba UTF-8',
            heading => 'Größe Überschrift',
            message => 'これは日本語のメッセージです。',
            items   => [
                'Café français',
                'Größe über älteren',
                'Niño español',
                '日本語テスト',
                '中文测试',
                'Тест кириллица',
                'Emoji 😀🎉',
            ]
        );
        $c->render(template => 'test-utf8/dynamic');
    });

    # Test rendering
    $t->get_ok('/test-utf8-dynamic')
      ->status_is(200)
      ->content_type_like(qr/text\/html/)
      ->content_like(qr/Página de Prueba UTF-8/, 'UTF-8 title')
      ->content_like(qr/Größe Überschrift/, 'UTF-8 heading')
      ->content_like(qr/これは日本語のメッセージです。/, 'Japanese message')
      ->content_like(qr/Café français/, 'French in list')
      ->content_like(qr/中文测试/, 'Chinese in list')
      ->content_like(qr/Emoji 😀🎉/, 'Emoji in list');

    # Cleanup
    $template_file->remove if -e $template_file;
    $template_dir->remove_tree if -d $template_dir;
};

subtest 'Form submission with UTF-8' => sub {
    my $template_dir = path('templates/test-utf8');
    $template_dir->make_path;

    my $form_template = $template_dir->child('form.html.ep');
    my $content = <<'TEMPLATE';
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>UTF-8 Form</title>
</head>
<body>
    <h1>UTF-8 Form Test</h1>
    <form method="POST" action="/test-utf8-submit">
        <input type="text" name="name" value="<%= param('name') || '' %>">
        <textarea name="description"><%= param('description') || '' %></textarea>
        <button type="submit">Submit</button>
    </form>
    % if (stash('submitted')) {
        <div>
            <h2>Submitted Data:</h2>
            <p>Name: <%= stash('submitted_name') %></p>
            <p>Description: <%= stash('submitted_description') %></p>
        </div>
    % }
</body>
</html>
TEMPLATE

    $form_template->spew($content);

    # Add form routes
    $t->app->routes->get('/test-utf8-form' => sub {
        my $c = shift;
        $c->render(template => 'test-utf8/form');
    });

    $t->app->routes->post('/test-utf8-submit' => sub {
        my $c = shift;
        my $name = $c->param('name');
        my $description = $c->param('description');

        $c->stash(
            submitted => 1,
            submitted_name => $name,
            submitted_description => $description,
        );
        $c->render(template => 'test-utf8/form');
    });

    # Test form submission with UTF-8 data
    my $utf8_name = 'José María García-López';
    my $utf8_description = "Descripción con acentos: niño, señora, café.\n日本語\nEmoji: 🎉";

    $t->post_ok('/test-utf8-submit' => form => {
        name => $utf8_name,
        description => $utf8_description,
    })
      ->status_is(200)
      ->content_like(qr/\Q$utf8_name\E/, 'UTF-8 name in response')
      ->content_like(qr/niño, señora, café/, 'Spanish characters in response')
      ->content_like(qr/日本語/, 'Japanese in response')
      ->content_like(qr/🎉/, 'Emoji in response');

    # Cleanup
    $form_template->remove if -e $form_template;
    $template_dir->remove_tree if -d $template_dir;
};

subtest 'JSON API with UTF-8' => sub {
    # Test JSON endpoints handle UTF-8 properly

    $t->app->routes->post('/test-utf8-json' => sub {
        my $c = shift;
        my $json = $c->req->json;

        # Echo back the JSON with some additions
        $json->{processed} = 1;
        $json->{server_message} = 'Сообщение от сервера';

        $c->render(json => $json);
    });

    # Test JSON with UTF-8
    my $test_json = {
        name => 'François Müller',
        city => '東京',
        notes => 'Test with émojis 🎯🚀',
        tags => ['café', 'größe', 'niño', '测试'],
    };

    $t->post_ok('/test-utf8-json' => json => $test_json)
      ->status_is(200)
      ->content_type_like(qr/application\/json/)
      ->json_is('/name', 'François Müller')
      ->json_is('/city', '東京')
      ->json_is('/notes', 'Test with émojis 🎯🚀')
      ->json_is('/tags/0', 'café')
      ->json_is('/tags/3', '测试')
      ->json_is('/server_message', 'Сообщение от сервера')
      ->json_is('/processed', 1);
};

done_testing;