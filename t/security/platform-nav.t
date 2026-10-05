#!/usr/bin/env perl
# ABOUTME: Every platform screen carries the nav, so none of them is reachable only by typing a URL.
# ABOUTME: The routes are walked rather than listed, so a new screen that forgets the nav fails here.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw( authenticate_as );
use Registry::DAO::Tenant;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $alex = Registry::DAO::Tenant->platform($db)->primary_user($db);
ok $alex, 'the platform tenant came with its owner';

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $dao } );
authenticate_as( $t, $alex );

# Walked, not listed. #472 happened because three screens were added one at a
# time and each was individually reachable while none linked to the others; a
# hardcoded list of three would have passed the whole way through that.
sub platform_screens ( $app ) {
    my @routes;
    my $walk;
    $walk = sub ( $r, $prefix ) {
        for my $child ( @{ $r->children } ) {
            my $path = $prefix . ( $child->pattern->unparsed // '' );
            my $name = $child->name // '';
            my @methods = @{ $child->methods // [] };

            push @routes, { path => $path, name => $name }
              if $path =~ m{^/platform/}
              && $name =~ /^platform_/
              && ( !@methods || grep { uc $_ eq 'GET' } @methods );

            $walk->( $child, $path );
        }
    };
    $walk->( $app->routes, '' );
    return @routes;
}

my @screens = platform_screens( $t->app );

subtest 'the walk finds the screens it is supposed to police' => sub {
    # If this ever reports zero, every assertion below would pass by vacuity --
    # the failure mode that makes a route-walking test worse than a list.
    ok scalar @screens, 'the route walk found platform screens at all';

    my %by_name = map { $_->{name} => $_->{path} } @screens;
    for my $expected (qw( platform_tenants platform_revenue platform_runbook )) {
        ok $by_name{$expected}, "$expected is among them ($by_name{$expected})"
          or diag 'found: ' . join ', ', sort keys %by_name;
    }
};

subtest 'every platform screen carries the nav, with every destination on it' => sub {
    for my $screen (@screens) {
        # Minion::Admin mounts its own pages under /platform/jobs; the plugin
        # renders them, so they cannot carry this nav. Linking INTO them is the
        # half that is ours, and the nav below is asserted to do it.
        next if $screen->{name} eq 'platform_jobs';

        $t->get_ok( $screen->{path} )->status_is( 200, "$screen->{path} renders" )
          ->content_like( qr/id="platform-nav"/,
              "$screen->{path} carries the platform nav" )
          ->content_like( qr/data-nav="platform_tenants"/,
              "$screen->{path} links to Tenants" )
          ->content_like( qr/data-nav="platform_revenue"/,
              "$screen->{path} links to Revenue" )
          ->content_like( qr/data-nav="platform_runbook"/,
              "$screen->{path} links to Runbook" )
          ->content_like( qr/data-nav="platform_jobs"/,
              "$screen->{path} links to the job queue" );
    }
};

subtest 'the screen you are on is marked, and only that one' => sub {
    # Without this a nav is four identical links and the operator cannot tell
    # where they are.
    $t->get_ok('/platform/revenue')->status_is(200)
      ->content_like( qr/data-nav="platform_revenue"[^>]*\bactive\b|\bactive\b[^>]*data-nav="platform_revenue"/,
          'the current screen is marked active' )
      ->content_like( qr/aria-current="page"/, 'and marked for a screen reader' );

    my $body = $t->tx->res->text;
    my @active = $body =~ /class="dashboard-nav-link active"/g;
    is scalar @active, 1, 'exactly one link is active';
};

done_testing;
