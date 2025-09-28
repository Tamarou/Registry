#!/usr/bin/env perl
use 5.40.2;
use lib qw(lib t/lib);
use Test::Registry::DB;
use Registry::DAO;

# Create database and deploy schema
my $db = Test::Registry::DB->new();

# Import workflows and templates immediately
my $dao = $db->db();
eval {
    $dao->import_workflows(['workflows/tenant-signup.yml']);
    $dao->import_templates(['registry']);
};

# Print just the URL
print $db->uri;