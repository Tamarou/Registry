# Registry Tenant Landing Page Spec

## Audience

Jordan -- art teacher, busy, discovering TinyArtEmpire for the first time via referral. Give her 30 seconds of scannable content.

## Design

Vaporwave/synthwave design system (theme.css + app.css). Text-driven, no images. Must use design system classes and CSS custom properties -- never Tailwind-style utility classes. See docs/design-system.md.

Mobile-first and responsive design. Follow the design system's responsive breakpoints and 44px minimum touch targets.

## Voice

Direct, practical, warm. Not salesy. Not clever.

## Page Structure

### 1. Hero -- The Why

- Headline connecting Jordan's identity as an artist to our promise
- One sentence bridging her pain to our solution
- **[Get Started]** CTA button (callcc to tenant-signup)

### 2. Problem Cards -- The How (6 scannable cards)

Each card: short headline + one sentence. No jargon. Jordan is an artist, not a business school graduate. These educate her on problems she may not know she has yet, roughly in the order she'd encounter them:

1. **Getting found / generating registrations** -- school CRM, parent pipeline
2. **Getting paid reliably** -- online payments, no check-chasing
3. **Managing the chaos** -- scheduling, attendance, waitlists, multi-child families
4. **Keeping in touch** -- parent communication, notifications
5. **Knowing your numbers** -- revenue tracking, throughput, in plain language
6. **Growing when you're ready** -- staff management when she scales

### 3. Alignment -- The Trust

- "Free to start. We only earn when you do."
- 2.5% revenue share as proof of shared incentives
- Not a pricing table -- a statement of belief

### 4. CTA -- Repeat

- Same **[Get Started]** button

## Technical Details

### Template Location

This is the `tenant-storefront/program-listing` template for the **registry tenant only**. The registry tenant's copy lives in the registry schema's `templates` table. The filesystem template is the initial version that seeds new tenant schemas.

### Data Source

Rendered by the `ProgramListing` workflow step (`Registry::DAO::WorkflowSteps::ProgramListing`). The step provides `programs` (array) and `run` (workflow run object). The template needs:

- `$run->id` for the callcc form action URL
- `$programs->[0]{project}->metadata->{registration_workflow}` for the callcc target workflow (resolves to `tenant-signup` for the registry tenant)

The rest of the ProgramListing data (sessions, pricing, enrollment counts) is available but not displayed on Jordan's landing page. It will be used when Alex runs multiple programs.

### CTA Mechanism

The "Get Started" button is a form POST to `/tenant-storefront/<run_id>/callcc/tenant-signup`. This creates a continuation and redirects Jordan into the tenant-signup workflow.

### Copy Writing

Delegate headline and card copy to a specialized copywriting agent. Voice: direct, practical, warm. Framework: Simon Sinek's "Start with Why" -- lead with shared belief, not features.

## Implementation Tasks

1. **Fix template import** -- `import_from_file` must not clobber existing DB templates (DONE)
2. **Fix filesystem template** -- rewrite `templates/tenant-storefront/program-listing.html.ep` using design system classes so new tenants start with a styled page
3. **Write Jordan's landing page** -- create the registry tenant's DB template with hero, problem cards, alignment section, and CTA
4. **Draft copy** -- delegate to copywriting agent for headlines and card descriptions
5. **Test** -- verify vaporwave styling renders, CTA callcc works, mobile responsive, design system classes used throughout

## Pushback Review

Reviewed 2026-04-10. All issues resolved. See conversation history for full review.

Key decisions:
- Template import no longer overwrites existing DB templates
- ProgramListing query left as-is (data will be useful when product grows)
- Analytics deferred to separate monitoring project
- Design system documentation added to CLAUDE.md and CONTRIBUTING.md
