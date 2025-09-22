#!/usr/bin/env perl
# ABOUTME: Minimal UTF-8 test without database dependency
# ABOUTME: Tests template rendering and form handling for UTF-8 characters

use 5.40.2;
use utf8;
use Test::More;
use Test::Mojo;

# Mock the DB to avoid connection issues during app startup
BEGIN {
    $ENV{DB_URL} = 'postgresql://test:test@nonexistent/test';
}

# Create a minimal test app without DB dependency
{
    package TestApp;
    use Mojolicious::Lite;

    # Add UTF-8 test route
    get '/utf8-test' => sub {
        my $c = shift;

        # Test with various UTF-8 strings
        $c->stash(
            french   => 'Café français',
            german   => 'Größe über älteren',
            spanish  => 'Niño español',
            japanese => '日本語テスト',
            chinese  => '中文测试',
            russian  => 'Тест кириллица',
            arabic   => 'مرحبا بالعالم',
            hebrew   => 'שלום עולם',
            emoji    => '😀🎉🌟',
        );

        $c->render(inline => <<'TEMPLATE');
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>UTF-8 Test</title>
</head>
<body>
    <h1>UTF-8 Character Test</h1>
    <p>French: <%= $french %></p>
    <p>German: <%= $german %></p>
    <p>Spanish: <%= $spanish %></p>
    <p>Japanese: <%= $japanese %></p>
    <p>Chinese: <%= $chinese %></p>
    <p>Russian: <%= $russian %></p>
    <p>Arabic: <%= $arabic %></p>
    <p>Hebrew: <%= $hebrew %></p>
    <p>Emoji: <%= $emoji %></p>
</body>
</html>
TEMPLATE
    };

    # Form test route
    post '/utf8-form' => sub {
        my $c = shift;
        my $name = $c->param('name');
        my $text = $c->param('text');

        $c->render(json => {
            received_name => $name,
            received_text => $text,
            name_length => length($name),
            text_length => length($text),
        });
    };

    app->start;
}

my $t = Test::Mojo->new('TestApp');

subtest 'UTF-8 rendering in templates' => sub {
    $t->get_ok('/utf8-test')
      ->status_is(200)
      ->content_type_like(qr/text\/html/)
      ->header_is('Content-Type' => 'text/html;charset=UTF-8', 'Correct charset header');

    # Check all UTF-8 strings are present
    my @test_strings = (
        'Café français',
        'Größe über älteren',
        'Niño español',
        '日本語テスト',
        '中文测试',
        'Тест кириллица',
        'مرحبا بالعالم',
        'שלום עולם',
        '😀🎉🌟',
    );

    for my $test_string (@test_strings) {
        $t->content_like(qr/\Q$test_string\E/, "Contains: $test_string");
    }
};

subtest 'UTF-8 form submission' => sub {
    my $utf8_name = 'José María García-López';
    my $utf8_text = "Text with: niño, café, 日本語, 😀";

    $t->post_ok('/utf8-form' => form => {
        name => $utf8_name,
        text => $utf8_text,
    })
      ->status_is(200)
      ->content_type_like(qr/application\/json/)
      ->json_is('/received_name', $utf8_name, 'Name preserved')
      ->json_is('/received_text', $utf8_text, 'Text preserved');
};

done_testing;