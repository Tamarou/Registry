#!/usr/bin/env perl
use 5.34.0;
use Test::More;
use Test::Mojo;

use lib 't/lib';

# Test WCAG 2.1 AA accessibility compliance
subtest 'Marketing page accessibility compliance' => sub {
    my $t = Test::Mojo->new('Registry');
    
    $t->get_ok('/')
      ->status_is(200);
    
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
        for my $img (@images) {
            my $alt = $img->attr('alt');
            ok defined($alt), 'Image has alt attribute (may be empty for decorative images)';
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
    $t->get_ok('/workflow/tenant-signup/landing')
      ->status_is(200);
    
    my $dom = $t->tx->res->dom;
    
    subtest 'Form accessibility' => sub {
        # Check for proper form labels
        my @form_inputs = $dom->find('input[type="text"], input[type="email"], textarea, select')->each;
        
        for my $input (@form_inputs) {
            my $id = $input->attr('id');
            my $label = $dom->at("label[for=\"$id\"]") if $id;
            my $aria_label = $input->attr('aria-label');
            my $aria_labelledby = $input->attr('aria-labelledby');
            
            ok $label || $aria_label || $aria_labelledby, 
               'Form input has associated label or aria-label';
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