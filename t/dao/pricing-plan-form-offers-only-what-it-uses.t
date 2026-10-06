#!/usr/bin/env perl
# ABOUTME: The plan-creation form stops collecting target_audience, which nothing ever read.
# ABOUTME: A field validated, stored and displayed back while no decision consults it is an offer the product does not keep.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Test::Registry::DB;
use Registry::DAO;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

subtest 'the form does not offer target_audience' => sub {
    # #427. It was validated as required, stored in run data and shown back on
    # two screens, and no pricing decision anywhere read it -- grep found
    # writers and display, never a consumer. Four choices were offered and the
    # answer changed nothing, which is the shape of #389 and #422.
    require Registry::DAO::WorkflowSteps::PricingPlanBasics;
    my $src = Mojo::File->new(
        'lib/Registry/DAO/WorkflowSteps/PricingPlanBasics.pm' )->slurp;

    unlike $src, qr/target_audiences\s*=>/,
        'the step offers no target_audience menu';
    unlike $src, qr/Target audience is required/,
        'and does not refuse a plan for lacking one';
    unlike $src, qr/target_audience\s*=>/,
        'nor stores it in run data';
};

subtest 'nothing downstream still expects it' => sub {
    for my $file (qw(
        lib/Registry/DAO/WorkflowSteps/ReviewActivatePlan.pm
        lib/Registry/DAO/WorkflowSteps/RequirementsRules.pm
        templates/pricing-plan-creation/plan-basics.html.ep
        templates/pricing-plan-creation/review-activate.html.ep
        templates/pricing-plan-creation/complete.html.ep
    )) {
        my $src = Mojo::File->new($file)->slurp;
        unlike $src, qr/target_audience/, "$file carries no target_audience";
    }
};

subtest 'pricing_model_type is NOT removed, because it is load-bearing' => sub {
    # Deliberately pinned. It reads like the same kind of dead vocabulary --
    # no price calculation consults it -- but PricingModel.pm branches on it to
    # decide which pricing_configuration shape to build, and
    # PriceOps::RevenueShare calls pricing_configuration->>'percentage' "the
    # only source" for the platform's rate. Drop the field and there is no way
    # left to author the plan shape Registry's own revenue share runs on.
    my $step = Mojo::File->new(
        'lib/Registry/DAO/WorkflowSteps/PricingModel.pm' )->slurp;
    like $step, qr/\$type eq 'percentage'/,
        'the percentage branch still exists';
    like $step, qr/percentage\s*=>\s*\$form_data->\{percentage_rate\}/,
        'and still writes the key RevenueShare reads';

    my $share = Mojo::File->new( 'lib/Registry/PriceOps/RevenueShare.pm' )->slurp;
    like $share, qr/pricing_configuration->>'percentage'/,
        'RevenueShare still reads it from the plan row';
};

subtest 'a plan can still be created without naming an audience' => sub {
    my $db = $dao->db;
    require Registry::DAO::PricingPlan;
    my $plan = Registry::DAO::PricingPlan->create( $db, {
        plan_name          => 'No Audience Plan',
        plan_type          => 'standard',
        pricing_model_type => 'fixed',
        amount_cents       => 5000,
    } );
    ok $plan, 'the plan is created';
    is $plan->plan_name, 'No Audience Plan', 'and keeps its name';
};

done_testing;
