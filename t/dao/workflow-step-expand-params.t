# ABOUTME: Unit tests for Registry::DAO::WorkflowStep->expand_form_params.
# ABOUTME: Covers bracket expansion, numeric-index arrayification, UUID key preservation, and sparse indices.
use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw(done_testing is_deeply subtest)];
defer { done_testing };

use Registry::DAO::WorkflowStep;

# expand_form_params and _arrayify_numeric_hashes are pure methods: no DB
# required.  We construct a minimal WorkflowStep with only the required :param
# fields so we can call the method directly.
my $step = Registry::DAO::WorkflowStep->new(
    id          => 'test-id',
    slug        => 'test-slug',
    workflow_id => 'test-workflow-id',
    description => 'test step',
    class       => 'Registry::DAO::WorkflowStep',
);

subtest 'flat non-bracketed keys pass through unchanged' => sub {
    my $result = $step->expand_form_params({ name => 'x', email => 'y' });
    is_deeply $result, { name => 'x', email => 'y' },
        'flat keys returned as-is';
};

subtest 'nested bracket notation is expanded into a hashref' => sub {
    my $result = $step->expand_form_params({ 'a[b][c]' => 1 });
    is_deeply $result, { a => { b => { c => 1 } } },
        'bracket notation expanded to nested hashref';
};

subtest 'numeric-indexed sub-hashes are converted to sorted arrayrefs' => sub {
    my $result = $step->expand_form_params({
        'team_members[0][name]' => 'A',
        'team_members[1][name]' => 'B',
    });
    is_deeply $result,
        { team_members => [ { name => 'A' }, { name => 'B' } ] },
        'integer-indexed keys arrayified in order';
};

subtest 'numeric sort is numeric not lexical (0..10 orders correctly)' => sub {
    my %input;
    for my $i ( 0 .. 10 ) {
        $input{"items[$i][n]"} = $i;
    }
    my $result = $step->expand_form_params(\%input);
    my @values = map { $_->{n} } $result->{items}->@*;
    is_deeply \@values, [ 0 .. 10 ],
        'indices 0-10 sorted numerically, not lexically (0 before 10)';
};

subtest 'UUID/non-numeric keys stay a hash (ConfigureLocation contract)' => sub {
    # A form field that must remain a MAP must use non-numeric keys (UUIDs,
    # slugs, etc.) because all-integer-keyed sub-hashes are converted to arrays
    # by design.
    my $result = $step->expand_form_params({
        'location_configs[abc-123][capacity]' => 5,
    });
    is_deeply $result,
        { location_configs => { 'abc-123' => { capacity => 5 } } },
        'UUID key keeps sub-hash as a hashref, not an arrayref';
};

subtest 'sparse numeric indices are compacted (gaps removed)' => sub {
    # Numeric indices are treated as ordering hints only; gaps are compacted so
    # team_members[0] + team_members[2] (no [1]) produces a 2-element arrayref.
    my $result = $step->expand_form_params({
        'team_members[0][name]' => 'Alice',
        'team_members[2][name]' => 'Carol',
    });
    is_deeply $result,
        { team_members => [ { name => 'Alice' }, { name => 'Carol' } ] },
        'sparse indices [0],[2] compacted to 2-element array';
};

subtest 'validation nesting: fields[N][validation][key]' => sub {
    my $result = $step->expand_form_params({
        'fields[0][validation][min]' => 1,
    });
    is_deeply $result,
        { fields => [ { validation => { min => 1 } } ] },
        'deeply nested validation sub-hash expanded and arrayified correctly';
};
