#!/usr/bin/env perl
# ABOUTME: WCAG-oriented checks on the pages an anonymous visitor reaches first.
# ABOUTME: Asserts no counterexample exists; never reports success for an absent element.
use 5.42.0;
use Test::More;
use Test::Mojo;

use lib qw(lib t/lib);
use Test::Registry::DB;
use Registry::DAO;
use Mojo::File;
use Mojo::Home;
use YAML::XS qw(Load);

# Every subtest here used to be shaped
#
#     if (@things) { ok ... for @things } else { pass('No things found') }
#
# so a page that lost its buttons, its links or its labels reported success
# rather than failure -- and two subtests were a bare pass() under a comment
# saying the check needed tooling we have. The rewrite states each rule as "no
# counterexample exists" and separately requires the elements that must be there:
# a landing page with no way in is broken, and saying so is the point.

# Setup test database
my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;

# Import workflows for workflow accessibility testing
my $workflow_dir = Mojo::Home->new->child('workflows');
my @files = $workflow_dir->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($dao, $file->slurp);
}

# Set environment for Test::Mojo
$ENV{DB_URL} = $dao->url;

# The accessible name of a control, by the same precedence a screen reader uses.
sub accessible_name ($el) {
    for my $candidate ( $el->attr('aria-label'), $el->attr('title'),
                        $el->attr('value'), $el->all_text )
    {
        return $candidate if defined $candidate && $candidate =~ /\S/;
    }
    return undef;
}

# Named rather than counted, so a failure says WHICH control is unreachable.
sub unnamed ($dom, $selector) {
    return [ map { $_->tag . ( $_->attr('id') ? '#' . $_->attr('id') : '' ) }
             grep { !defined accessible_name($_) }
             $dom->find($selector)->each ];
}

subtest 'the landing page an anonymous visitor reaches' => sub {
    my $t = Test::Mojo->new('Registry');
    $t->get_ok('/')->status_is(200);
    my $dom = $t->tx->res->dom;

    ok $dom->at('html'), 'Page has HTML element';
    ok $dom->at('body'), 'Page has body element';
    ok $dom->at('title'), 'Page has title element';

    # A landing page with no link is a dead end, so this is a requirement and
    # not a condition. The old version passed when there were none.
    my $links = $dom->find('a[href]');
    ok $links->size > 0, 'the landing page offers at least one link'
        or diag 'a landing page with nothing to follow cannot be entered';
    is_deeply unnamed($dom, 'a[href]'), [], 'every link has an accessible name';

    is_deeply unnamed($dom, 'button, [role="button"], input[type="submit"]'), [],
        'every button has an accessible name';

    # A page may legitimately carry no images. The rule is about the ones it has,
    # so it is stated as an absence of counterexamples rather than a pass for an
    # empty list.
    my @imgs_without_alt =
      grep { !defined $_->attr('alt') } $dom->find('img')->each;
    is scalar @imgs_without_alt, 0,
        'no image is missing its alt attribute (empty alt is fine, absent is not)';

    # Keyboard reach: something must be focusable, and the focus ring has to be
    # defined somewhere real. The old check looked for :focus in inline <style>
    # blocks, which the layout does not use, so it always took the branch that
    # passed with the message "Focus styles should be defined in CSS".
    ok $dom->find('a, button, input, select, textarea, [tabindex]')->size > 0,
        'the page has something a keyboard can reach';
    like Mojo::File->new('public/css/app.css')->slurp, qr/:focus/,
        'the stylesheet defines a focus appearance';
};

subtest 'the first workflow screen' => sub {
    my $t = Test::Mojo->new('Registry');

    my $res = $t->get_ok('/tenant-signup')->tx->res;
    if ($res->code == 302) {
        $t->get_ok($res->headers->location)->status_is(200);
    }
    else {
        is $res->code, 200, '200 OK';
    }

    my $dom = $t->tx->res->dom;

    # This step is an introduction: it has buttons and no inputs, which is why
    # the input rule below is an absence-of-counterexamples rule. The button
    # rule is a requirement -- a workflow step with no control cannot be left.
    ok $dom->find('button, [role="button"], input[type="submit"]')->size > 0,
        'the step offers a control to continue with';
    is_deeply unnamed($dom, 'button, [role="button"], input[type="submit"]'), [],
        'every button has an accessible name';

    my @unlabelled;
    for my $input ( $dom->find(
        'input[type="text"], input[type="email"], textarea, select')->each )
    {
        my $id = $input->attr('id');
        next if $id && $dom->at(qq{label[for="$id"]});
        next if $input->attr('aria-label') || $input->attr('aria-labelledby');
        push @unlabelled, $input->attr('name') // $input->tag;
    }
    is_deeply \@unlabelled, [],
        'no form control is without a label or aria-label';
};

# Two subtests are deliberately absent rather than faked. They were:
#
#   pass('Color contrast should be verified with automated accessibility tools');
#   pass('Error message accessibility requires form submission testing');
#
# Neither asserted anything, and both described work rather than doing it.
# Contrast needs a rendering engine -- it belongs in a Playwright spec with
# axe-core, against the real stylesheet and both themes. Error-message
# announcement needs a form driven to failure and the resulting markup checked
# for role="alert". Tracked rather than simulated.

done_testing;
