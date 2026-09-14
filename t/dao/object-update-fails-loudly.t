#!/usr/bin/env perl
# ABOUTME: Registry::DAO::Object::update must not swallow a failed write.
# ABOUTME: Money-path callers persisted intent ids through it and could not tell.

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO;
use Registry::DAO::Tenant;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $tenant = Registry::DAO::Tenant->create( $db,
    { name => 'Update Probe', slug => 'update_probe' } );

subtest 'a successful update returns the new object' => sub {
    my $updated = $tenant->update( $db, { name => 'Update Probe Renamed' } );
    ok $updated, 'an object comes back';
    is $updated->name, 'Update Probe Renamed', 'carrying the new value';

    my $reread = Registry::DAO::Tenant->find( $db, { id => $tenant->id } );
    is $reread->name, 'Update Probe Renamed', 'and the row really moved';
};

# update() wrapped the UPDATE in try/catch and carp'd, returning undef, so a
# caller could not tell a failed persist from a successful one. Payment's
# create_payment_intent persisted Stripe intent ids and statuses through this:
# a database failure there left the row and the live Stripe object disagreeing,
# with a warning on stderr as the only trace.
subtest 'a rejected write dies rather than warning' => sub {
    # tenants_slug_is_lowercase refuses this, which makes it a real database
    # error rather than a simulated one.
    my $err;
    eval { $tenant->update( $db, { slug => 'MixedCase' } ); 1 } or $err = $@;

    ok $err, 'the failure propagates' or return;
    unlike $err, qr/\A\s*\z/, 'with a message';

    my $reread = Registry::DAO::Tenant->find( $db, { id => $tenant->id } );
    is $reread->slug, 'update_probe', 'and the row is unchanged';
};

# Equally silent before: the UPDATE matched nothing, ->hash returned undef, and
# dereferencing it threw inside the same try that swallowed real errors.
subtest 'an update matching no row dies' => sub {
    my $err;
    eval {
        $tenant->update( $db, { name => 'Still Not There' },
            { id => '00000000-0000-0000-0000-0000000000ff' } );
        1;
    } or $err = $@;
    ok $err, 'updating a row that is not there is an error, not a no-op';
};

done_testing;
