#!/usr/bin/env perl
# ABOUTME: Tests that the dashboard layout provides role-aware navigation.
# ABOUTME: Validates admin, staff, and parent users see appropriate nav links.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw(done_testing ok subtest)];
defer { done_testing };

use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::Helpers qw(authenticate_as import_all_workflows);

my $test_db = Test::Registry::DB->new;
my $dao = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

import_all_workflows($dao);

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

# Create users with different roles
my $admin = $dao->create(User => { username => 'nav_admin', user_type => 'admin', name => 'Admin User', email => 'admin@test.com' });
my $staff = $dao->create(User => { username => 'nav_teacher', user_type => 'staff', name => 'Teacher User', email => 'teacher@test.com' });

subtest 'admin sees full navigation on dashboard' => sub {
    authenticate_as($t, $admin);

    $t->get_ok('/admin/dashboard')
      ->status_is(200)
      ->element_exists('nav.dashboard-nav', 'Dashboard has navigation bar')
      ->element_exists('nav.dashboard-nav a[href="/admin/dashboard"]', 'Nav has admin dashboard link')
      ->element_exists('nav.dashboard-nav a[href="/program-creation"]', 'Nav has program creation link')
      ->element_exists('nav.dashboard-nav a[href="/admin/templates"]', 'Nav has template editor link')
      ->element_exists('nav.dashboard-nav a[href="/teacher/"]', 'Nav has teacher dashboard link')
      ->element_exists('nav.dashboard-nav a[href="/admin/domains"]', 'Nav has domain management link');
};

subtest 'teacher sees limited navigation on teacher dashboard' => sub {
    authenticate_as($t, $staff);

    $t->get_ok('/teacher/')
      ->status_is(200)
      ->element_exists('nav.dashboard-nav', 'Dashboard has navigation bar')
      ->element_exists('nav.dashboard-nav a[href="/admin/dashboard"]', 'Nav has admin dashboard link')
      ->element_exists('nav.dashboard-nav a[href="/teacher/"]', 'Nav has teacher dashboard link');
};

subtest 'navigation shows current user context' => sub {
    authenticate_as($t, $admin);

    $t->get_ok('/admin/dashboard')
      ->status_is(200)
      ->content_like(qr/Admin User/, 'Shows current user name');
};
