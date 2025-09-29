#!/usr/bin/env perl
use 5.40.2;
use lib 'lib';

say "Testing module loading...";

eval {
    require Registry::DAO::WorkflowSteps::ReviewActivatePlan;
    1;
} or do {
    say "Error loading module: $@";

    # Try to find the actual line
    if ($@ =~ /line (\d+)/) {
        my $line = $1;
        say "Error at line $line";

        open my $fh, '<', 'lib/Registry/DAO/WorkflowSteps/ReviewActivatePlan.pm';
        my @lines = <$fh>;
        close $fh;

        say "Context around line $line:";
        for my $i (($line-3)..($line+2)) {
            next if $i < 0 || $i > $#lines;
            printf "%4d: %s", $i+1, $lines[$i];
        }
    }
};