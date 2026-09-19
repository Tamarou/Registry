#!/usr/bin/env perl
# ABOUTME: Every DAO class a workflow step calls must be reachable when that step runs.
# ABOUTME: A step naming a class nobody loads fails only for the person walking the screen.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw(done_testing note ok subtest)];
defer { done_testing };
our $TODO;

# Load the app the way a web process does, and NOTHING else. Registry::DAO is
# the aggregator every controller and step pulls in.
#
# This file must never require a DAO class on behalf of a step before pass 1
# has run. Doing so is what makes this kind of test worthless: it proves the
# class exists on disk, which was never in doubt, instead of proving it is
# loaded on the path a parent walks. The first draft of this test did exactly
# that and passed with the bug reintroduced.
use Registry::DAO;
use Registry::DAO::WorkflowSteps;

my ( @needs_aggregator, %self_loaded );
for my $file ( glob 'lib/Registry/DAO/WorkflowSteps/*.pm lib/Registry/DAO/WorkflowSteps/*/*.pm' ) {
    open my $fh, '<', $file or next;
    my $src   = do { local $/; <$fh> };
    my $short = $file =~ s{.*/}{}r;

    while ( $src =~ /\b(Registry::DAO::[A-Za-z][A-Za-z:]*)->(\w+)\(/g ) {
        my ( $class, $method ) = ( $1, $2 );
        next if $class =~ /WorkflowSteps/;

        # A step that loads its own class carries its dependency; one that does
        # not is relying on the aggregator to have carried it.
        if ( $src =~ /^\s*(?:use|require)\s+\Q$class\E\b/m ) {
            $self_loaded{$class}{$method}{$short} = 1;
        }
        else {
            push @needs_aggregator, [ $class, $method, $short ];
        }
    }
}

ok @needs_aggregator, 'found steps relying on the aggregator';
note sprintf '%d aggregator-reliant calls, %d self-loading classes',
    scalar @needs_aggregator, scalar keys %self_loaded;

# PASS 1 -- must run before this process requires any DAO class. can() on an
# unloaded class is false, and that is the entire discriminator: one stray
# require above would silently turn this green.
subtest 'a class a step does not load itself is reachable from Registry::DAO' => sub {
    for my $call ( sort { "@$a" cmp "@$b" } @needs_aggregator ) {
        my ( $class, $method, $caller ) = @$call;
        ok $class->can($method), "$class->$method is loaded for $caller";
    }
};

# PASS 2 -- steps that require the class themselves. Loading is allowed now.
# Registry::DAO::Program has no file and no class declaration anywhere, so it
# cannot be fixed by loading it: TODO rather than skip, so the day someone
# writes that class this goes green and the exemption becomes deletable. See #396.
my %KNOWN_BROKEN = ( 'Registry::DAO::Program' => 'no such class anywhere in lib/ -- see #396' );

subtest 'a class a step loads itself can actually be loaded' => sub {
    for my $class ( sort keys %self_loaded ) {
        my $loaded = do {
            local $TODO = $KNOWN_BROKEN{$class};
            my $ok = eval "require $class; 1";
            ok $ok, "$class loads when a step requires it";
            $ok;
        };
        next unless $loaded;

        for my $method ( sort keys $self_loaded{$class}->%* ) {
            my $callers = join ', ', sort keys $self_loaded{$class}{$method}->%*;
            ok $class->can($method), "$class->$method exists (required by $callers)";
        }
    }
};
