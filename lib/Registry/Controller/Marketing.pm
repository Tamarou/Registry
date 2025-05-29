use 5.40.0;
use Object::Pad;

class Registry::Controller::Marketing :isa(Registry::Controller) {

    method index {
        # Enhanced SEO metadata
        my $current_url = $self->req->url->to_abs;
        my $canonical_url = $self->url_for('/')->to_abs;
        
        $self->stash(
            # Basic SEO
            title => 'Registry - After-School Program Management Made Simple',
            description => 'Streamline your after-school programs with Registry. Manage registrations, track attendance, handle payments, and communicate with families. 30-day free trial.',
            keywords => 'after-school programs, registration software, program management, student tracking, attendance, payments, school administration, enrollment system',
            
            # Open Graph / Social Media
            og_title => 'Registry - After-School Program Management Software',
            og_description => 'Complete solution for managing after-school programs. Registration, attendance, payments, and parent communication in one platform.',
            og_image => $self->url_for('/images/registry-social-preview.png')->to_abs,
            og_url => $canonical_url,
            og_type => 'website',
            
            # Twitter Card
            twitter_card => 'summary_large_image',
            twitter_title => 'Registry - After-School Program Management',
            twitter_description => 'Streamline your after-school programs with comprehensive management tools.',
            twitter_image => $self->url_for('/images/registry-twitter-card.png')->to_abs,
            
            # Technical SEO
            canonical_url => $canonical_url,
            robots => 'index, follow',
            language => 'en-US',
            
            # Schema.org structured data
            schema_data => $self->_generate_schema_data(),
            
            # Performance hints
            preconnect_domains => [
                'https://js.stripe.com',
                'https://fonts.googleapis.com',
                'https://fonts.gstatic.com'
            ]
        );
        
        $self->render( template => 'marketing/index' );
    }

    method _generate_schema_data {
        return {
            '@context' => 'https://schema.org',
            '@type' => 'SoftwareApplication',
            name => 'Registry',
            description => 'Complete after-school program management software solution',
            url => $self->url_for('/')->to_abs,
            applicationCategory => 'BusinessApplication',
            operatingSystem => 'Web Browser',
            offers => {
                '@type' => 'Offer',
                price => '200.00',
                priceCurrency => 'USD',
                priceValidUntil => '2025-12-31',
                availability => 'https://schema.org/InStock',
                description => 'Monthly subscription with 30-day free trial'
            },
            provider => {
                '@type' => 'Organization',
                name => 'Registry',
                url => $self->url_for('/')->to_abs,
                contactPoint => {
                    '@type' => 'ContactPoint',
                    telephone => '1-800-REGISTRY',
                    email => 'support@registry.com',
                    contactType => 'Customer Support'
                }
            },
            featureList => [
                'Student Registration Management',
                'Attendance Tracking',
                'Payment Processing',
                'Parent Communication',
                'Waitlist Management',
                'Staff Scheduling',
                'Reporting and Analytics'
            ],
            screenshot => $self->url_for('/images/registry-screenshot.png')->to_abs
        };
    }
}