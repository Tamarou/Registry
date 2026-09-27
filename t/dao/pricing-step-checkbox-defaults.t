# ABOUTME: Tests that an unticked checkbox on the pricing-plan steps means "no", quietly.
# ABOUTME: A browser omits an unticked checkbox entirely, so these keys are routinely absent.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# Six sites compared a form value to 'yes' without guarding it, and every one is a
# checkbox -- the single control a browser does not send when the user leaves it
# alone. So the absent-key path was not an edge case, it was the common one: each
# of these warned "Use of uninitialized value in string eq" on an ordinary submit.
#
# The answer was right (undef eq 'yes' is false), which is why it survived as noise
# rather than a bug report. The risk is that an unguarded eq beside a boolean
# decision becomes a real defect the moment somebody inverts the sense.
my $workflow = Registry::DAO::Workflow->create($db, {
    name => 'Checkbox Defaults', slug => 'checkbox-defaults',
    description => 'Drives the pricing steps with checkboxes absent',
});

my %step;
for my $spec (
    [ 'requirements-rules'  => 'Registry::DAO::WorkflowSteps::RequirementsRules' ],
    [ 'resource-allocation' => 'Registry::DAO::WorkflowSteps::ResourceAllocation' ],
) {
    my ( $slug, $class ) = @$spec;
    Registry::DAO::WorkflowStep->create($db, {
        workflow_id => $workflow->id, slug => $slug,
        class => $class, description => $slug,
    });
    # Re-found, because create() blesses into the base class and find() is what
    # loads the subclass named in the `class` column.
    $step{$slug} = Registry::DAO::WorkflowStep->find($db,
        { workflow_id => $workflow->id, slug => $slug });
    isa_ok $step{$slug}, $class;
}
$workflow->update($db, { first_step => 'requirements-rules' }, { id => $workflow->id });

# Warnings are the assertion, not a side note: the whole report was noise in the
# test log, so a fix that silences the value without silencing the warning has
# fixed nothing.
sub warnings_from ($cb) {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    $cb->();
    return \@warnings;
}

subtest 'unticked checkboxes on requirements-rules mean no, silently' => sub {
    my $run = $workflow->new_run($db);

    # Exactly what a browser posts when the user fills nothing in and submits:
    # the checkbox keys are simply not there.
    my $warnings = warnings_from( sub {
        $step{'requirements-rules'}->process( $db, { action => 'continue' }, $run );
    } );

    is_deeply [ grep { /uninitialized/ } @$warnings ], [],
        'no uninitialized-value warning' or diag explain $warnings;

    my $rules = $dao->find( WorkflowRun => { id => $run->id } )
        ->data->{requirements_rules}{rules};

    is $rules->{auto_renew},           0, 'auto_renew defaults to 0';
    is $rules->{prorate_on_upgrade},   0, 'prorate_on_upgrade defaults to 0';
    is $rules->{prorate_on_downgrade}, 0, 'prorate_on_downgrade defaults to 0';
};

subtest 'a ticked checkbox still means yes' => sub {
    my $run = $workflow->new_run($db);

    $step{'requirements-rules'}->process( $db, {
        action             => 'continue',
        auto_renew         => 'yes',
        prorate_on_upgrade => 'yes',
    }, $run );

    my $rules = $dao->find( WorkflowRun => { id => $run->id } )
        ->data->{requirements_rules}{rules};

    is $rules->{auto_renew},           1, 'auto_renew is 1 when sent';
    is $rules->{prorate_on_upgrade},   1, 'prorate_on_upgrade is 1 when sent';
    is $rules->{prorate_on_downgrade}, 0, 'and the one not sent is still 0';
};

subtest 'an unticked checkbox on resource-allocation means no, silently' => sub {
    my $run = $workflow->new_run($db);

    # One resource supplied, because the step refuses a form that allocates
    # nothing at all -- correctly, and it returns before reaching the flags. The
    # checkbox keys are still absent, which is the case under test.
    my $warnings = warnings_from( sub {
        $step{'resource-allocation'}->process( $db,
            { action => 'continue', classes_per_month => 4 }, $run );
    } );

    is_deeply [ grep { /uninitialized/ } @$warnings ], [],
        'no uninitialized-value warning' or diag explain $warnings;

    my $data = $dao->find( WorkflowRun => { id => $run->id } )
        ->data->{resource_allocation};

    is $data->{quotas}{rollover_allowed}, 0, 'rollover_allowed defaults to 0';

    # peak_hours_access is NOT asserted as 0: its assignment sits inside
    # `if ($form_data->{peak_hours_access})`, so an absent checkbox leaves the key
    # out entirely rather than setting it false. That enclosing test is also why
    # the eq there never needed guarding -- it cannot be reached with an undef.
    ok !exists $data->{resources}{peak_hours_access},
        'peak_hours_access is absent rather than false, which is what the code does';
};

done_testing;
