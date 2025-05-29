# Tenant Onboarding Workflow Enhancement Specification

## Overview

Enhance the existing tenant onboarding system to provide a complete, production-ready experience from marketing page through tenant creation with subscription billing.

## Current State Assessment

### ✅ Working Components
- Core workflow infrastructure (4-step tenant-signup workflow)
- Database schema and multi-tenant isolation
- Business logic (`Registry::DAO::Tenant`, `RegisterTenant` step)
- Basic templates structure
- Comprehensive test coverage

### 🔧 Needs Enhancement
- Public marketing page (entry point)
- Template quality and user experience
- Progress indicator system (reusable across all workflows)
- Stripe subscription integration
- Team member creation workflow
- Payment collection and validation

## Detailed Requirements

### 1. Public Marketing Page

**Location**: Default "Registry" tenant root page (`/`)

**Content Structure**:
- **Hero Section**
  - Clear value proposition headline
  - "Get Started" CTA button linking directly to tenant-signup workflow
- **Features/Benefits Showcase**
  - Key Registry capabilities
  - What organizations get when they sign up
- **Pricing Information**
  - $200/month subscription
  - 30-day free trial
  - Clear billing terms

**Technical Requirements**:
- Mobile responsive design
- Matches existing Registry design system
- Fast loading and SEO optimized

### 2. Progress Indicator Web Component

**Component**: `<workflow-progress>`

**Features**:
- Breadcrumb-style navigation
- Shows step numbers and names
- Allows backward navigation
- Pulls data from database via controller
- Responsive and accessible

**Data Integration**:
- Controller embeds step data as HTML data attributes
- Attributes include: `data-current-step`, `data-total-steps`, `data-step-urls`, `data-step-names`, `data-completed-steps`
- HTMX handles navigation between steps

**Usage**:
- Reusable across ALL Registry workflows
- Self-contained component
- Keyboard navigation support
- ARIA labels for accessibility

### 3. Enhanced Tenant-Signup Workflow

#### Step 1: Welcome/Orientation (landing)

**Purpose**: Reassure and set expectations

**Content**:
- Welcome message and process overview
- Time estimate: "This will take about 5 minutes"
- Capabilities preview: "You'll be able to create programs and accept enrollments"
- Trial terms: "30-day free trial, cancel anytime"
- Next steps preview: "We'll collect your organization details and create your admin account"
- Support information: "Need help? Email support@registry.com"
- Progress indicator showing "Step 1 of 4"

**Technical**:
- Enhanced template with proper layout
- HTMX integration
- Progress indicator component

#### Step 2: Organization Profile (profile)

**Purpose**: Collect minimum billing/legal requirements

**Fields Required**:
- Organization name (for billing and subdomain generation)
- Billing address (complete address for tax/legal compliance)
- Primary contact email (for billing notifications)
- Phone number (for account security)

**Auto-Generation**:
- Subdomain: `organization-name-as-slug.registry.com`
- Help text explaining CNAME aliasing for custom domains

**Technical**:
- Form validation (client and server-side)
- Real-time subdomain preview
- Error handling with user-friendly messages

#### Step 3: Team Setup (users)

**Purpose**: Create admin account and invite team members

**Functionality**:
- Create primary admin user (Jordan) with full admin privileges
- Invite additional team members (Morgan) with role selection
- Use enhanced user-creation workflow (reusable from admin panel)
- Role options: Admin, Staff, Instructor (expandable for future granular permissions)

**Technical**:
- Integrate with existing user-creation workflow
- Extend workflow to support role assignment
- Email invitation system for team members
- Progressive enhancement for adding multiple users

#### Step 4: Review & Confirmation (complete)

**Purpose**: Final review before payment processing

**Content Display**:
- Summary of organization setup (name, domain, team members)
- Post-payment timeline and login instructions
- First-login suggestions and onboarding checklist
- Support resources and documentation links
- 30-day trial terms and cancellation policy
- Clear CTA: "Complete Setup & Start Trial"

**Technical**:
- Comprehensive data review interface
- Smooth transition to payment processing

### 4. Stripe Subscription Integration

**Billing Configuration**:
- $200/month subscription with 30-day trial
- Stripe Customer record creation with organization details
- Payment method collection (no immediate charge)
- Automatic invoice collection and retry logic
- Subscription ID storage in tenant record

**Payment Flow**:
- Stripe Elements integration for secure payment collection
- Payment method verification before tenant creation
- Tenant creation only after successful Stripe setup
- Webhook handling for subscription events (cancelled, past_due, etc.)

**Error Handling**:
- Payment setup retry mechanism (up to 3 attempts)
- Block tenant creation after 3 failed payment attempts
- Clear error messaging and retry options
- Graceful degradation for payment failures

### 5. Technical Implementation Details

#### Template Enhancements
- Fix existing typos ("Regstry" → "Registry")
- Implement proper form validation
- Add HTMX integration for dynamic behavior
- Progress indicators on all steps
- Mobile-responsive design
- Error state handling

#### Controller Updates
- Enhanced `Registry::Controller::Tenants`
- Progress indicator data embedding
- Improved error handling and user feedback
- Integration with Stripe payment processing

#### Database Considerations
- Store Stripe customer and subscription IDs in tenant records
- Billing status tracking
- Trial period management

#### Security & Validation
- Input sanitization for all form fields
- Password requirements enforcement
- Email validation and verification
- CSRF protection
- Rate limiting for signup attempts

### 6. Testing Requirements

#### Unit Tests
- Web component functionality
- Form validation logic
- Stripe integration methods
- Progress indicator data generation

#### Integration Tests
- Complete onboarding flow from marketing page to tenant creation
- Payment failure and retry scenarios
- Team member invitation workflow
- Progress indicator navigation

#### User Experience Tests
- Mobile responsiveness
- Accessibility compliance (WCAG 2.1)
- Performance under load
- Cross-browser compatibility

### 7. Success Metrics

- Onboarding completion rate
- Time to complete signup process
- Payment failure/retry rates
- User satisfaction with signup experience
- Support ticket volume for onboarding issues

## Implementation Priority

1. **Phase 1**: Progress indicator web component (enables better UX across all workflows)
2. **Phase 2**: Marketing page and welcome step enhancement
3. **Phase 3**: Form improvements and validation (steps 2-4)
4. **Phase 4**: Stripe subscription integration
5. **Phase 5**: Team setup workflow enhancements
6. **Phase 6**: Testing and polish

## Future Considerations

- Granular permission system architecture
- Custom domain setup workflow
- Organization onboarding checklist/wizard
- Advanced billing features (annual plans, discounts)
- Multi-language support
- Integration marketplace

---

This specification provides a complete roadmap for transforming the existing tenant onboarding infrastructure into a production-ready, conversion-optimized signup experience.