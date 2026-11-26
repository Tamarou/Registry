#!/usr/bin/env perl
# ABOUTME: Solo's current version must list a run right for every non-draft workflow shipped in workflows/ (less never_copied).
# ABOUTME: A workflow shipped without a new Solo version listing it would be granted to no studio: this fails until one does.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Mojo::Home;
use YAML::XS ();

use Test::Registry::DB;
use Registry::PriceOps::PlatformTerms ();
use Registry::WorkflowDivergence;

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;

my @shipped = sort grep { !Registry::WorkflowDivergence::never_copied($_) }
    map  { $_->{slug} } grep { !$_->{draft} }
    map  { YAML::XS::Load( $_->slurp ) } Mojo::Home->new->child('workflows')->list->grep(qr/\.ya?ml$/)->each;

my %listed = map { $_->[0] => 1 } $db->query( q{
    SELECT r.name FROM registry.offer_versions v
      JOIN registry.offer_version_resources s ON s.offer_version_id = v.id
      JOIN registry.resources r ON r.id = s.resource_id
     WHERE v.offer_id = ? AND v.published_at IS NOT NULL AND v.superseded_at IS NULL
}, $Registry::PriceOps::PlatformTerms::SOLO_OFFER_ID )->arrays->each;

subtest 'no workflow ships without a run right in Solo current version' => sub {
    ok scalar @shipped, 'workflows/ ships workflows';
    my @missing = grep { !$listed{"run:$_"} } @shipped;
    is_deeply \@missing, [],
        'every shipped workflow has a run right in Solo\'s current version'
        or diag "Shipped with no run right in Solo's current version: @missing. A new workflow is granted to "
        . 'no studio until a new Solo version lists it: publish one (a sqitch change, as solo-grants-workflow-set did).';
};

done_testing;
