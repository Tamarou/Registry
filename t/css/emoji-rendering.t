use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing ok subtest )];
defer { done_testing };

# ABOUTME: Tests that emoji font-family is specified on icon containers
# ABOUTME: Ensures emojis render correctly rather than as blank squares across platforms

use Test::Mojo;
use Registry;
use Test::Registry::DB;

my $test_db = Test::Registry::DB->new();
$ENV{DB_URL} = $test_db->uri;

my $t = Test::Mojo->new('Registry');

subtest 'landing feature icon has emoji font-family' => sub {
    $t->get_ok('/css/app.css')
      ->status_is(200)
      ->content_like(
          qr/\.landing-feature-icon[^}]*font-family[^}]*(?:Apple Color Emoji|Noto Color Emoji|emoji)[^}]*\}/s,
          'landing-feature-icon specifies emoji font-family'
      );
};

subtest 'workflow icon class has emoji font-family' => sub {
    $t->get_ok('/css/app.css')
      ->status_is(200)
      ->content_like(
          qr/\.icon[^}]*font-family[^}]*(?:Apple Color Emoji|Noto Color Emoji|emoji)[^}]*\}/s,
          '.icon class specifies emoji font-family'
      );
};
