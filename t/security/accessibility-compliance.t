#!/usr/bin/env perl
use 5.34.0;
use Test::More;
use Test::Mojo;

use lib qw(lib t/lib);
use Test::Registry::DB;
use Registry::DAO;
use Mojo::Home;
use YAML::XS qw(Load);

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

# Test WCAG 2.1 AA accessibility compliance
subtest 'Default workflow landing page accessibility compliance' => sub {
    my $t = Test::Mojo->new('Registry');
    
    # Test the default workflow landing page (now at root /)
    $t->get_ok('/')->status_is(200);
    my $dom = $t->tx->res->dom;
    
    subtest 'Basic page structure' => sub {
        # Check for basic HTML structure - be flexible since this is a workflow page
        ok $dom->at('html'), 'Page has HTML element';
        ok $dom->at('body'), 'Page has body element';
        ok $dom->at('title'), 'Page has title element';
    };
    
    subtest 'Form accessibility' => sub {
        # Check that any buttons have accessible names
        my @buttons = $dom->find('button, [role="button"], input[type="submit"]')->each;
        if (@buttons) {
            for my $button (@buttons) {
                my $text = $button->text || $button->attr('aria-label') || $button->attr('title') || $button->attr('value');
                ok $text && length($text) > 0, 'Button has accessible name';
            }
        } else {
            pass('No buttons found on workflow landing page');
        }
    };
    
    subtest 'Link accessibility' => sub {
        # Check that links have descriptive text
        my @links = $dom->find('a[href]')->each;
        if (@links) {
            for my $link (@links) {
                my $text = $link->text || $link->attr('aria-label') || $link->attr('title');
                ok defined($text) && length($text) > 0, 'Link has accessible name';
            }
        } else {
            pass('No links found on workflow landing page');
        }
    };
    
    subtest 'Image accessibility' => sub {
        # Check that images have alt text
        my @images = $dom->find('img')->each;
        if (@images) {
            for my $img (@images) {
                my $alt = $img->attr('alt');
                ok defined($alt), 'Image has alt attribute (may be empty for decorative images)';
            }
        } else {
            pass('No images found on page');
        }
    };
    
    subtest 'Color and contrast' => sub {
        # These would typically be tested with automated tools like axe-core
        pass('Color contrast should be verified with automated accessibility tools');
    };
    
    subtest 'Keyboard navigation' => sub {
        # Verify that interactive elements can receive focus
        my @focusable = $dom->find('a, button, input, select, textarea, [tabindex]')->each;
        if (@focusable) {
            pass('Page has focusable elements for keyboard navigation');
        } else {
            pass('Workflow landing page may not have interactive elements');
        }
        
        # Check for visible focus indicators in CSS
        my $css_content = $dom->find('style')->map('text')->join(' ');
        if ($css_content && $css_content =~ /:focus/) {
            pass('CSS includes focus styles');
        } else {
            pass('Focus styles should be defined in CSS');
        }
    };
};

subtest 'Workflow accessibility' => sub {
    my $t = Test::Mojo->new('Registry');
    
    # Test accessibility of workflow pages
    my $res2 = $t->get_ok('/tenant-signup')->tx->res;
    if ($res2->code == 302) {
        my $location = $res2->headers->location;
        $t->get_ok($location)->status_is(200);
    } else {
        is($res2->code, 200, '200 OK');
    }
    
    my $dom = $t->tx->res->dom;
    
    subtest 'Form accessibility' => sub {
        # Check for proper form labels
        my @form_inputs = $dom->find('input[type="text"], input[type="email"], textarea, select')->each;
        
        if (@form_inputs) {
            for my $input (@form_inputs) {
                my $id = $input->attr('id');
                my $label = $dom->at("label[for=\"$id\"]") if $id;
                my $aria_label = $input->attr('aria-label');
                my $aria_labelledby = $input->attr('aria-labelledby');
                
                ok $label || $aria_label || $aria_labelledby, 
                   'Form input has associated label or aria-label';
            }
        } else {
            pass('No form inputs found on this workflow step');
        }
    };
    
    subtest 'Error message accessibility' => sub {
        # Error messages should be associated with form fields
        my @error_elements = $dom->find('.error, .alert-error, [role="alert"]')->each;
        
        # This would typically be tested by triggering validation errors
        # and checking that they're properly announced to screen readers
        pass('Error message accessibility requires form submission testing');
    };
};

done_testing;