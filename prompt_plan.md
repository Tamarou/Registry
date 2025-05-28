# Tenant Onboarding Enhancement Implementation Plan

## Overview

This document provides a step-by-step implementation plan for enhancing the Registry tenant onboarding system, broken down into small, testable iterations. Each prompt builds on the previous work, ensuring no orphaned code and continuous integration.

## Project Goals

Transform the existing tenant onboarding infrastructure into a production-ready experience including:
- Public marketing page with clear conversion flow
- Reusable progress indicator web component for all workflows
- Enhanced 4-step onboarding process
- Stripe subscription integration with 30-day trial
- Team member setup workflow
- Comprehensive testing and polish

## Implementation Strategy

### Principles
- Test-driven development for all new components
- Incremental progress with working features at each step
- Reuse existing Registry patterns (Object::Pad, Mojolicious, HTMX)
- Maintain multi-tenant isolation
- Progressive enhancement for accessibility

### Phase Approach
1. **Foundation**: Core infrastructure and reusable components
2. **Enhancement**: Improve existing onboarding steps
3. **Integration**: Add payment processing and team setup
4. **Polish**: Testing, optimization, and production readiness

---

## Implementation Steps

### Step 1: Progress Indicator Web Component Foundation ✅

```text
Create a reusable progress indicator web component that can be used across all Registry workflows.

Technical Requirements:
1. Create `public/js/components/workflow-progress.js` as a Web Component
2. Implement `<workflow-progress>` custom element with:
   - Breadcrumb-style visual design
   - Data attribute configuration (data-current-step, data-total-steps, data-step-names, data-step-urls)
   - Backward navigation capability with HTMX integration
   - Mobile responsive design
   - Accessibility features (ARIA labels, keyboard navigation)

3. Add CSS styles in existing stylesheet for:
   - Breadcrumb visual design matching Registry theme
   - Step states: completed, current, upcoming
   - Mobile responsiveness
   - Hover and focus states

4. Write comprehensive tests:
   - Unit tests for component initialization
   - Navigation functionality tests
   - Accessibility compliance tests
   - Responsive design verification

5. Create test workflow template to verify component works
6. Update layouts/workflow.html.ep to include the component script

Success Criteria:
- Web component registers and renders correctly
- Data attributes properly configure the component
- Navigation works with HTMX
- Passes accessibility audit
- Works on mobile devices
```

### Step 2: Workflow Controller Enhancement for Progress Data ✅

```text
Enhance the workflow processing system to provide progress indicator data to templates.

Technical Requirements:
1. Update `Registry::Controller::Workflows` to include progress data:
   - Add `_get_workflow_progress` method that queries workflow_steps table
   - Generate step URLs for navigation
   - Calculate current position and completion status
   - Embed data as template variables

2. Modify workflow template rendering to:
   - Pass progress data to all workflow templates
   - Include progress indicator component automatically
   - Handle step navigation validation (prevent skipping required steps)

3. Update workflow base template:
   - Add progress indicator component with proper data attributes
   - Ensure it displays on all workflow pages
   - Style integration with existing layout

4. Write tests for:
   - Progress data generation accuracy
   - Step URL generation
   - Navigation permission logic
   - Template integration

5. Test with existing workflows to ensure no regressions

Success Criteria:
- All existing workflows show progress indicator
- Navigation between completed steps works
- Current workflow step displays correctly
- No performance impact on workflow rendering
```

### Step 3: Marketing Page for Default Tenant ✅

```text
Create a public marketing page for the default "Registry" tenant that serves as the entry point for new tenant onboarding.

Technical Requirements:
1. Create new route in default tenant configuration:
   - GET / for default tenant (Registry)
   - Separate from other tenant root pages

2. Create `Registry::Controller::Marketing` with:
   - `index` action for marketing page
   - SEO metadata configuration
   - Analytics tracking setup (if needed)

3. Create marketing page template `templates/marketing/index.html.ep`:
   - Hero section with compelling headline and "Get Started" CTA
   - Features/benefits showcase (4-6 key features)
   - Pricing section ($200/month, 30-day free trial)
   - Footer with support information
   - Mobile-responsive design

4. Implement "Get Started" button:
   - Direct link to tenant-signup workflow start
   - Proper URL generation for workflow entry
   - Tracking/analytics integration

5. Write tests for:
   - Marketing page rendering
   - Content accuracy
   - CTA button functionality
   - Mobile responsiveness
   - SEO metadata

6. Style with existing Registry design system

Success Criteria:
- Marketing page loads at default tenant root
- "Get Started" button launches tenant onboarding
- Page is mobile responsive and accessible
- All content displays correctly
- Performance meets standards
```

### Step 4: Enhanced Welcome Step Template ✅

```text
Transform the tenant-signup workflow's first step into a comprehensive welcome/orientation experience.

Technical Requirements:
1. Enhance `templates/tenant-signup/index.html.ep`:
   - Fix typo ("Regstry" → "Registry")
   - Add welcome messaging with reassurance
   - Include time estimate and process overview
   - Add trial terms and cancellation policy
   - Provide support contact information
   - Preview next steps

2. Integrate progress indicator:
   - Show "Step 1 of 4" clearly
   - Enable proper workflow navigation
   - Test backward navigation (should be disabled on first step)

3. Add HTMX enhancements:
   - Smooth transitions between workflow steps
   - Loading states for navigation
   - Error handling for workflow issues

4. Improve visual design:
   - Match Registry branding
   - Add appropriate imagery or icons
   - Ensure mobile responsiveness
   - Improve typography and spacing

5. Write tests for:
   - Template rendering with all content
   - Progress indicator integration
   - HTMX functionality
   - Mobile display
   - Accessibility compliance

6. Update workflow YAML if needed for better step naming

Success Criteria:
- Welcome step provides clear orientation
- Users understand the process and commitment
- Progress indicator shows correct position
- Template is visually appealing and professional
- All functionality works as expected
```

### Step 5: Enhanced Profile Collection Step ✅

```text
Improve the organization profile collection step to gather minimum required billing information with excellent UX.

Technical Requirements:
1. Enhance `templates/tenant-signup/profile.html.ep`:
   - Add comprehensive form for billing requirements
   - Organization name (with real-time subdomain preview)
   - Complete billing address fields
   - Primary contact email and phone
   - Form validation (client and server-side)

2. Implement subdomain generation:
   - Real-time preview of `orgname.registry.com`
   - Slug generation from organization name
   - Validation for subdomain availability
   - Help text about custom domain CNAME options

3. Add form enhancements:
   - Progressive enhancement with HTMX
   - Field validation with user-friendly errors
   - Loading states during validation
   - Accessibility features (proper labels, error announcements)

4. Update `Registry::DAO::WorkflowSteps::RegisterTenant`:
   - Handle new profile fields
   - Validate subdomain uniqueness
   - Store billing information securely
   - Generate tenant subdomain

5. Write comprehensive tests:
   - Form validation (client and server)
   - Subdomain generation and uniqueness
   - Data storage and retrieval
   - Error handling scenarios
   - Accessibility compliance

Success Criteria:
- Form collects all required billing information
- Subdomain preview works in real-time
- Validation provides clear, helpful feedback
- Data is stored correctly for later billing
- Form is accessible and mobile-friendly
```

### Step 6: Team Setup Workflow Enhancement ✅

```text
Enhance the user creation step to support comprehensive team setup with role assignment.

Technical Requirements:
1. Extend existing user-creation workflow:
   - Add role selection capability
   - Support multiple user creation in sequence
   - Integrate with tenant-signup workflow
   - Maintain backward compatibility

2. Update `Registry::DAO::WorkflowSteps::CreateUser`:
   - Add role assignment during user creation
   - Support basic roles: Admin, Staff, Instructor
   - Set primary user as full admin automatically
   - Handle email invitations for additional users

3. Enhance `templates/tenant-signup/users.html.ep`:
   - Replace simple "Add User" link with comprehensive interface
   - Show primary admin user creation form
   - Add interface for inviting additional team members
   - Display role selection with clear descriptions
   - Use HTMX for dynamic user addition

4. Create reusable team management component:
   - Can be used later in admin panel
   - Handles user invitation flow
   - Manages role assignments
   - Provides user list management

5. Update user invitation system:
   - Send email invitations to team members
   - Track invitation status
   - Handle invitation acceptance flow
   - Secure invitation tokens

6. Write tests for:
   - Primary user creation with admin role
   - Team member invitation flow
   - Role assignment functionality
   - Email invitation system
   - Multi-user workflow integration

Success Criteria:
- Primary admin user is created successfully
- Team members can be invited with appropriate roles
- Invitation emails are sent and processed
- Role assignments work correctly
- Interface is intuitive and accessible
```

### Step 7: Stripe Subscription Integration Foundation ✅

```text
Create the Stripe subscription infrastructure for $200/month billing with 30-day trial.

Technical Requirements:
1. Add Stripe subscription dependencies:
   - Update cpanfile with required Stripe modules
   - Configure Stripe API keys in environment
   - Set up webhook endpoint infrastructure

2. Create `Registry::DAO::Subscription`:
   - Handle Stripe customer creation
   - Manage subscription setup with trial
   - Store customer and subscription IDs
   - Process webhook events
   - Handle billing failures and retries

3. Create subscription configuration:
   - Define $200/month product in Stripe
   - Configure 30-day trial period
   - Set up automatic invoice collection
   - Configure retry logic for failed payments

4. Add database schema for subscription tracking:
   - Extend tenants table with Stripe IDs
   - Track billing status and trial information
   - Store subscription metadata

5. Create webhook handler:
   - `Registry::Controller::Webhooks::Stripe`
   - Handle subscription status changes
   - Process payment failures and retries
   - Update tenant billing status

6. Write comprehensive tests:
   - Stripe customer creation
   - Subscription setup with trial
   - Webhook processing
   - Billing failure scenarios
   - Database integration

Success Criteria:
- Stripe integration works in test mode
- Subscriptions are created with 30-day trial
- Webhook events are processed correctly
- Billing status is tracked accurately
- Error handling works for payment failures
```

### Step 8: Payment Collection Step Implementation ✅

```text
Add payment collection as the final step of tenant onboarding with Stripe Elements integration.

Technical Requirements:
1. Create new payment step in tenant-signup workflow:
   - Add 'payment' step after 'users' step
   - Update workflow YAML configuration
   - Ensure proper step ordering and navigation

2. Create `Registry::DAO::WorkflowSteps::Payment`:
   - Generate Stripe customer from profile data
   - Create subscription with trial period
   - Handle payment method collection
   - Verify payment method before tenant creation
   - Process failed payment attempts (max 3 retries)

3. Create payment template `templates/tenant-signup/payment.html.ep`:
   - Summary of signup details
   - Stripe Elements payment form
   - Trial terms and billing information
   - Clear error messaging and retry options
   - Loading states and success confirmations

4. Integrate with tenant creation:
   - Only create tenant after successful payment setup
   - Store Stripe customer and subscription IDs
   - Activate trial period
   - Send confirmation emails

5. Implement retry logic:
   - Track payment attempt count
   - Allow up to 3 retry attempts
   - Block tenant creation after 3 failures
   - Provide clear error messages and support contact

6. Write comprehensive tests:
   - Payment method collection and validation
   - Subscription creation with trial
   - Tenant creation flow integration
   - Retry logic and failure scenarios
   - Error handling and user feedback

Success Criteria:
- Payment collection works seamlessly
- Tenant is only created after successful payment setup
- Trial period is properly configured
- Retry logic handles failures gracefully
- User experience is smooth and professional
```

### Step 9: Review and Confirmation Step Enhancement ✅

```text
Transform the completion step into a comprehensive review and confirmation interface before payment.

Technical Requirements:
1. Move completion content to before payment step:
   - Reorder workflow steps: landing → profile → users → review → payment
   - Update workflow YAML and step routing
   - Ensure proper navigation flow

2. Create comprehensive review template:
   - Organization summary (name, subdomain, contact info)
   - Team member list with roles
   - Billing and trial information
   - What happens after payment
   - Next steps and onboarding checklist
   - Support resources and documentation links

3. Add confirmation interactions:
   - Edit buttons for each section (go back to specific steps)
   - Final terms and conditions acceptance
   - Clear "Complete Setup & Start Trial" button
   - Progress indicator showing final step before payment

4. Implement edit functionality:
   - Allow users to go back and modify information
   - Preserve form data when navigating between steps
   - Show updated information when returning to review
   - Validate that all required information is complete

5. Add pre-payment validation:
   - Verify all required fields are completed
   - Check subdomain availability one final time
   - Validate team member information
   - Ensure terms acceptance

6. Write tests for:
   - Review page data display accuracy
   - Edit functionality and data persistence
   - Pre-payment validation
   - Terms acceptance requirement
   - Navigation flow integrity

Success Criteria:
- Users can review all their information before payment
- Edit functionality works smoothly
- All data validation passes before payment
- User feels confident proceeding to payment
- Clear expectations are set for post-payment experience
```

### Step 10: Post-Creation Success Flow ✅

```text
Implement the post-tenant-creation success experience with onboarding guidance.

Technical Requirements:
1. Create post-payment success page:
   - Confirmation of successful setup
   - Tenant access information (subdomain, login details)
   - Trial period information and billing schedule
   - Immediate next steps checklist

2. Implement tenant activation flow:
   - Send welcome email with login credentials
   - Provide getting started guide
   - Include links to documentation and support
   - Set up initial onboarding checklist in new tenant

3. Create onboarding email templates:
   - Welcome email with account details
   - Getting started guide with first steps
   - Trial reminder emails (7 days before trial ends)
   - Support and resource information

4. Add tenant setup automation:
   - Create default admin user in new tenant
   - Set up basic configuration
   - Import initial workflows and templates
   - Configure default settings

5. Implement success tracking:
   - Track successful tenant creation metrics
   - Monitor onboarding completion rates
   - Set up analytics for conversion funnel
   - Create alerts for failed tenant creations

6. Write tests for:
   - Success page rendering and content
   - Email template generation and sending
   - Tenant activation automation
   - User login and access verification
   - Onboarding checklist functionality

Success Criteria:
- Users receive clear confirmation of successful setup
- Login credentials and access information are provided
- Welcome emails are sent automatically
- New tenant is properly configured and accessible
- Onboarding guidance sets users up for success
```

### Step 11: Error Handling and Edge Cases ✅

```text
Implement comprehensive error handling and edge case management throughout the onboarding flow.

Technical Requirements:
1. Payment failure scenarios:
   - Credit card declined handling
   - Insufficient funds scenarios
   - Invalid payment method errors
   - Stripe service outage handling
   - Clear retry instructions and support contact

2. Data validation and conflicts:
   - Subdomain already exists handling
   - Email address conflicts
   - Organization name duplication
   - Invalid data format errors
   - Cross-step validation consistency

3. Workflow interruption handling:
   - Session timeout recovery
   - Browser refresh/back button behavior
   - Incomplete workflow resumption
   - Data persistence across interruptions
   - Clear re-entry instructions

4. System integration failures:
   - Database connection issues
   - Email service failures
   - Stripe API outages
   - Webhook processing failures
   - Graceful degradation strategies

5. User experience improvements:
   - Clear error messaging for all scenarios
   - Contextual help and support options
   - Progress preservation during errors
   - Alternative contact methods when automated systems fail
   - Accessibility for error states

6. Monitoring and alerting:
   - Error rate tracking and alerts
   - Failed onboarding attempt monitoring
   - Performance metric tracking
   - Support ticket integration for failures

7. Write comprehensive tests:
   - All error scenarios and recovery paths
   - Edge case handling
   - Error message clarity and helpfulness
   - System resilience under failure conditions
   - User workflow interruption and resumption

Success Criteria:
- All error scenarios have clear, helpful messaging
- Users can recover from errors and complete onboarding
- System gracefully handles external service failures
- Support team is alerted to critical failures
- Error rates are monitored and tracked
```

### Step 12: Performance Optimization and Production Polish ✅

```text
Optimize the onboarding experience for production performance and professional polish.

Technical Requirements:
1. Performance optimization:
   - Page load time optimization
   - Database query optimization for workflow steps
   - Image optimization and lazy loading
   - JavaScript bundle optimization
   - CDN configuration for static assets

2. SEO and discoverability:
   - Marketing page SEO optimization
   - Meta tags and structured data
   - Social media sharing optimization
   - Search engine indexing configuration
   - Analytics and conversion tracking

3. Security hardening:
   - Input sanitization and validation
   - CSRF protection on all forms
   - Rate limiting for signup attempts
   - SQL injection prevention verification
   - XSS protection testing

4. Accessibility compliance:
   - WCAG 2.1 AA compliance verification
   - Screen reader testing
   - Keyboard navigation testing
   - Color contrast verification
   - Focus management optimization

5. Mobile optimization:
   - Touch-friendly interface elements
   - Mobile-specific interactions
   - Responsive design verification
   - Mobile performance optimization
   - Cross-device testing

6. Browser compatibility:
   - Cross-browser testing (Chrome, Firefox, Safari, Edge)
   - Progressive enhancement verification
   - Fallback behavior for unsupported features
   - Polyfill configuration
   - Graceful degradation testing

7. Production monitoring:
   - Application performance monitoring
   - Error tracking and alerting
   - Conversion funnel analytics
   - User behavior tracking
   - System health monitoring

8. Write comprehensive tests:
   - Performance benchmarking
   - Security vulnerability scanning
   - Accessibility compliance testing
   - Cross-browser functionality testing
   - Load testing for high traffic scenarios

Success Criteria:
- Page load times under 3 seconds
- Passes all accessibility audits
- Works correctly across all major browsers
- Handles traffic spikes gracefully
- Meets security best practices
- Provides clear analytics and monitoring
```

## Integration Testing and Quality Assurance

### End-to-End Testing Suite

```text
Create comprehensive end-to-end testing covering the complete tenant onboarding journey.

Test Coverage:
1. Marketing page to tenant creation flow
2. Payment processing and Stripe integration
3. Team setup and invitation workflow
4. Error scenarios and recovery paths
5. Performance under load
6. Security vulnerability testing
7. Accessibility compliance verification
8. Mobile device testing
9. Cross-browser compatibility
10. Email delivery and template testing

Success Metrics:
- 95%+ test coverage for new components
- Sub-3-second page load times
- 99.9% uptime during onboarding flow
- Zero security vulnerabilities
- WCAG 2.1 AA compliance
- 90%+ onboarding completion rate
```

## Implementation Notes

### Development Principles
- Each step builds incrementally on previous work
- No orphaned or unused code
- Strong test coverage for all new functionality
- Progressive enhancement for accessibility
- Mobile-first responsive design
- Security by design

### Integration Strategy
- Leverage existing Registry patterns and infrastructure
- Maintain backward compatibility
- Reuse components across workflows
- Follow established coding standards
- Maintain multi-tenant isolation

### Quality Assurance
- Test-driven development approach
- Continuous integration and deployment
- Performance monitoring and optimization
- Security auditing and vulnerability testing
- User experience testing and feedback

---

This implementation plan transforms the tenant onboarding experience through careful, incremental improvements that build on Registry's existing solid foundation while adding the polish and functionality needed for production success.