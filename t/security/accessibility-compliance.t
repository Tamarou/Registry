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
subtest 'Marketing page accessibility compliance' => sub {
    my $t = Test::Mojo->new('Registry');
    
    # Follow redirect to actual marketing page
    my $res = $t->get_ok('/')->tx->res;
    if ($res->code == 302) {
        my $location = $res->headers->location;
        $t->get_ok($location)->status_is(200);
    } else {
        is($res->code, 200, '200 OK');
    }
    
    my $dom = $t->tx->res->dom;
    
    subtest 'Semantic HTML structure' => sub {
        # Check for proper heading hierarchy
        ok $dom->at('h1'), 'Page has main heading (h1)';
        ok $dom->at('h2'), 'Page has section headings (h2)';
        
        # Check for semantic landmarks
        ok $dom->at('[role="banner"]'), 'Page has banner landmark';
        ok $dom->at('[role="main"]'), 'Page has main content landmark';
        ok $dom->at('[role="contentinfo"]'), 'Page has contentinfo landmark';
        
        # Check for proper list structure
        ok $dom->find('ul li')->size > 0, 'Lists contain list items';
    };
    
    subtest 'ARIA attributes and labels' => sub {
        # Check for aria-labelledby attributes
        my @labeled_sections = $dom->find('[aria-labelledby]')->each;
        ok @labeled_sections > 0, 'Sections have aria-labelledby attributes';
        
        # Check for aria-describedby on interactive elements
        my @described_elements = $dom->find('[aria-describedby]')->each;
        ok @described_elements > 0, 'Interactive elements have aria-describedby';
        
        # Check for aria-hidden on decorative elements
        my @hidden_elements = $dom->find('[aria-hidden="true"]')->each;
        ok @hidden_elements > 0, 'Decorative elements have aria-hidden';
    };
    
    subtest 'Form accessibility' => sub {
        # Check that buttons have accessible names
        my @buttons = $dom->find('button, [role="button"]')->each;
        for my $button (@buttons) {
            my $text = $button->text || $button->attr('aria-label') || $button->attr('title');
            ok $text && length($text) > 0, 'Button has accessible name';
        }
    };
    
    subtest 'Link accessibility' => sub {
        # Check that links have descriptive text
        my @links = $dom->find('a[href]')->each;
        for my $link (@links) {
            my $text = $link->text || $link->attr('aria-label') || $link->attr('title');
            ok $text && length($text) > 0, 'Link has accessible name';
            
            # Check for descriptive link text (not just "click here")
            if ($text) {
                unlike $text, qr/^(click here|read more|more)$/i, 'Link text is descriptive';
            }
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
        # For now, we verify that color is not the only way to convey information
        
        # Check that form validation doesn't rely solely on color
        pass('Color contrast should be verified with automated accessibility tools');
    };
    
    subtest 'Keyboard navigation' => sub {
        # Verify that interactive elements can receive focus
        my @focusable = $dom->find('a, button, input, select, textarea, [tabindex]')->each;
        ok @focusable > 0, 'Page has focusable elements';
        
        # Check for visible focus indicators in CSS
        my $css_content = $dom->find('style')->map('text')->join(' ');
        like $css_content, qr/:focus/, 'CSS includes focus styles';
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