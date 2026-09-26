# ABOUTME: Tests the workflow-progress web component's script and its data contract.
# ABOUTME: The component is never instantiated by any template -- see #423.
use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok like unlike is_deeply subtest )];
defer { done_testing };

use Mojolicious::Lite;
use Test::Mojo;

# This file used to hold eleven pass() calls, eight of which asserted nothing at
# all: a comment, sometimes a Perl string containing JavaScript that was never
# executed, and a pass() underneath it.
#
#     pass('Accessibility tests defined (require browser environment)');
#     pass('Component lifecycle tests defined');
#
# Registry has Playwright, so "requires a browser environment" was not a reason
# even when it was written. What is left here is what a Perl test can actually
# check about this component: that its script is served, that it registers the
# element it claims to, and what its data contract is. Whether the component is
# reachable at all is #423 -- no template emits <workflow-progress>, so the
# script is loaded on every workflow page and never runs.

app->static->paths(['public']);

my $t = Test::Mojo->new;

subtest 'the component script is served' => sub {
    $t->get_ok('/js/components/workflow-progress.js')
      ->status_is(200)
      ->content_type_like(qr/javascript/);
};

subtest 'it registers the element the layout would have to emit' => sub {
    $t->get_ok('/js/components/workflow-progress.js')->status_is(200);
    my $js = $t->tx->res->body;

    # The name is the contract between the script and any template that wants
    # the progress bar. #423 is that no template holds up the other end.
    like $js, qr/customElements\.define\(\s*'workflow-progress'/,
        'defines the custom element workflow-progress';
    like $js, qr/class\s+WorkflowProgress\s+extends\s+HTMLElement/,
        'as an element, not a behaviour bolted to a div';

    # The attributes it reads. A template that emits the element has to supply
    # these names, and the layout currently emits them on a <main> the component
    # does not claim.
    like $js, qr/data-current-step/,  'reads data-current-step';
    like $js, qr/data-total-steps/,   'reads data-total-steps';
    like $js, qr/data-step-names/,    'reads data-step-names';
    like $js, qr/data-step-urls/,     'reads data-step-urls';
    like $js, qr/data-completed-steps/, 'reads data-completed-steps';
};

subtest 'it announces navigation rather than performing it' => sub {
    $t->get_ok('/js/components/workflow-progress.js')->status_is(200);
    my $js = $t->tx->res->body;

    # The step labels are clickable, and the component dispatches an event
    # instead of assigning location -- which is what lets a page decide whether
    # a jump backwards is allowed.
    like $js, qr/workflow-navigation/, 'dispatches a workflow-navigation event';
    unlike $js, qr/window\.location\s*=/,
        'and does not navigate on its own';
};
