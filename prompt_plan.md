# Registry MVP Implementation Plan

## Overview

This document provides a step-by-step implementation plan for the Registry MVP, broken down into small, testable iterations. Each prompt builds on the previous work, ensuring no orphaned code and continuous integration.

## Foundation Phase: Core Data Models

### Step 1: Program Type Configuration ✅

```text
Using the existing Registry codebase (Perl/Mojolicious with PostgreSQL), implement a program type configuration system. 

Create a new table `program_types` with fields:
- id (uuid)
- slug (text, unique) 
- name (text)
- config (jsonb) containing:
  - enrollment_rules (e.g., same_session_for_siblings: true/false)
  - standard_times (e.g., { monday: "15:00", wednesday: "14:00" })
  - session_pattern (e.g., weekly_for_x_weeks, daily_for_x_days)
- created_at, updated_at

Write:
1. Sqitch migration to create the table
2. DAO class Registry::DAO::ProgramType with create, get, list methods
3. Tests for the DAO ensuring program types can be created and retrieved
4. Seed data migration for 'afterschool' and 'summer-camp' types

Make sure the DAO follows the existing patterns using Object::Pad and integrates with the multi-tenant system.
```

### Step 2: Enhanced Pricing Model ✅

```text
Extend the existing pricing system to support PriceOps-style flexible pricing plans.

Modify the pricing table structure to support:
- Multiple pricing tiers per session (rename table to pricing_plans)
- plan_name (text)
- plan_type (enum: 'standard', 'early_bird', 'family')
- amount (decimal)
- installments_allowed (boolean)
- installment_count (integer)
- requirements (jsonb) - for early bird dates, family size, etc.

Write:
1. Sqitch migration to transform existing pricing table
2. Update Registry::DAO::Event to work with new pricing structure
3. Add methods: create_pricing_plan, get_pricing_plans, calculate_price
4. Tests verifying multiple plans per session and price calculation logic
5. Ensure backward compatibility with existing enrollments

The pricing should integrate with the session system and maintain tenant isolation.
```

### Step 3: Attendance Tracking Infrastructure ✅

```text
Implement the attendance tracking data model and basic operations.

Create attendance tracking tables:
- attendance_records:
  - id (uuid)
  - event_id (uuid, FK)
  - student_id (uuid, FK)  
  - status (enum: 'present', 'absent')
  - marked_at (timestamp)
  - marked_by (uuid, FK to users)

Write:
1. Sqitch migration for attendance tables
2. Registry::DAO::Attendance with mark_attendance, get_event_attendance methods
3. Add constraints to prevent duplicate attendance records
4. Tests for marking attendance and retrieving attendance records
5. Add indexes for performance on event_id and student_id

Ensure the DAO handles the relationship between events, enrollments, and attendance.
```

### Step 4: Waitlist Management

```text
Add waitlist functionality to the enrollment system.

Create waitlist table:
- id (uuid)
- session_id (uuid, FK)
- location_id (uuid, FK) 
- student_id (uuid, FK)
- parent_id (uuid, FK)
- position (integer)
- status (enum: 'waiting', 'offered', 'expired', 'declined')
- offered_at (timestamp)
- expires_at (timestamp)

Write:
1. Sqitch migration for waitlist table
2. Registry::DAO::Waitlist with join_waitlist, process_waitlist methods
3. Add trigger to automatically reorder positions when entries are removed
4. Tests for waitlist operations including position management
5. Method to check if student is already enrolled or waitlisted

The waitlist should respect the location-specific capacity constraints.
```

## Phase 1: School Landing Pages

### Step 5: Public School Pages Route

```text
Implement public-facing school landing pages that don't require authentication.

Create:
1. New controller Registry::Controller::Schools
2. Route: GET /school/:slug that:
   - Loads location by slug
   - Fetches active sessions at that location
   - Groups by program/project
   - Calculates available spots
3. Template templates/schools/show.html.ep displaying:
   - School name
   - List of programs with required info
   - "Enroll" buttons linking to enrollment workflow
4. Tests verifying:
   - Public access (no auth required)
   - Only current tenant's programs shown
   - Correct available spots calculation

Use HTMX for dynamic updates if needed. Ensure mobile-responsive design.
```

### Step 6: Program Discovery Enhancements

```text
Enhance the school landing page with better program discovery features.

Add to the school pages:
1. Session filtering by:
   - Age/grade requirements
   - Start date
   - Program type (afterschool vs summer camp)
2. Visual indicators for:
   - Programs filling up (< 20% spots left)
   - Early bird pricing active
   - Waitlist available
3. Program cards showing:
   - Name, description (truncated)
   - Date range
   - Price (showing early bird if applicable)
   - Spots remaining or waitlist status
4. Tests for all display logic and filtering

Implement using HTMX for filter updates without page reload.
```

## Phase 2: Enhanced Enrollment

### Step 7: Multi-Child Data Model

```text
Extend the enrollment system to support multiple children per family.

Add to users/families:
1. Create family_members table:
   - id (uuid)
   - family_id (uuid, FK to users)
   - child_name (text)
   - birth_date (date)
   - grade (text)
   - medical_info (jsonb)
   - created_at, updated_at
2. Registry::DAO::Family with:
   - add_child, update_child, list_children methods
   - Method to check age/grade eligibility
3. Update enrollment to reference family_member_id
4. Tests for family management operations

This maintains backward compatibility while enabling multi-child support.
```

### Step 8: Enrollment Workflow Enhancement - Account Creation

```text
Integrate account creation into the enrollment workflow using continuations.

Modify enrollment workflow:
1. Add new step after landing: 'account_check'
2. Create Registry::DAO::WorkflowSteps::AccountCheck that:
   - Checks if user is logged in
   - If not, uses continuation to launch user-creation workflow
   - Stores user_id in workflow run data upon return
3. Template showing "Login" or "Create Account" options
4. Update subsequent steps to use stored user_id
5. Tests for:
   - Continuation flow to user creation
   - Data persistence across continuation
   - Logged-in user bypass

Follow the existing continuation patterns from tenant-signup workflow.
```

### Step 9: Enrollment Workflow - Multi-Child Support

```text
Add multi-child enrollment capability to the workflow.

Enhance enrollment workflow:
1. After account creation/login, add 'select_children' step
2. Create Registry::DAO::WorkflowSteps::SelectChildren that:
   - Lists existing children for the family
   - Allows adding new child inline
   - Stores selected child IDs in workflow data
3. Modify 'session-selection' to:
   - Loop through selected children
   - Apply program type rules (same session for afterschool)
   - Store selections per child
4. Update payment step to calculate total for all children
5. Tests for:
   - Multiple child selection
   - Program type rule enforcement
   - Correct price calculation

Use HTMX for dynamic child addition without losing form state.
```

### Step 10: Payment Integration Foundation

```text
Integrate Stripe payment processing into the enrollment workflow.

Implement payment foundation:
1. Add Stripe Perl module to cpanfile
2. Create Registry::DAO::Payment with:
   - create_payment_intent method
   - process_payment method
   - Store payment records in new payments table
3. Add Registry::DAO::WorkflowSteps::Payment that:
   - Calculates total (including discounts)
   - Creates Stripe payment intent
   - Handles success/failure callbacks
4. Payment confirmation template with Stripe Elements
5. Tests using Stripe test mode for:
   - Payment intent creation
   - Successful payment flow
   - Payment failure handling

Store Stripe configuration in environment variables.
```

## Phase 3: Program Management

### Step 11: Program Creation Workflow

```text
Implement the program creation workflow for Morgan.

Create new workflow:
1. Add workflows/program-creation-enhanced.yml with steps:
   - program_type_selection
   - curriculum_details
   - requirements_and_patterns
   - review_and_create
2. Create DAO steps for each workflow step
3. ProgramTypeSelection: Choose from configured types
4. CurriculumDetails: Name, description, learning objectives
5. RequirementsAndPatterns: Age/grade, staff needs, custom schedule
6. Store complete program definition in projects table metadata
7. Tests for complete program creation flow

Ensure the workflow captures all needed program information.
```

### Step 12: Location Assignment Workflow

```text
Create workflow for assigning programs to locations.

Implement location assignment:
1. Create workflows/program-location-assignment.yml
2. Steps:
   - Select existing program (from projects)
   - Choose locations (with multi-select)
   - Configure per-location details
   - Generate events
3. Registry::DAO::WorkflowSteps::ConfigureLocation:
   - Set capacity based on location
   - Adjust times using program type defaults
   - Override pricing if needed
4. Registry::DAO::WorkflowSteps::GenerateEvents:
   - Create all events based on pattern
   - Assign to session
   - Set teacher placeholders
5. Tests for multi-location event generation

Support bulk operations for efficiency.
```

### Step 13: Teacher Assignment with Conflict Detection

```text
Add teacher assignment with conflict checking.

Enhance the system:
1. Create Registry::DAO::Schedule with:
   - get_teacher_schedule method
   - check_conflicts method (time + travel time)
   - assign_teacher method
2. Add to event generation:
   - Teacher selection interface
   - Conflict checking before assignment
   - Warning system with override option
3. Configuration for travel time between locations
4. Update session_teachers for assignments
5. Tests for:
   - Conflict detection
   - Travel time calculation
   - Override functionality

Show visual schedule grid for easier assignment.
```

## Phase 4: Operations

### Step 14: Teacher Attendance Interface

```text
Create mobile-friendly attendance taking interface for teachers.

Implement teacher interface:
1. Registry::Controller::TeacherDashboard
2. Route: GET /teacher/attendance/:event_id
3. Mobile-optimized template showing:
   - Event details (time, location, program)
   - Student list with big touch-friendly buttons
   - Present/Absent toggle for each student
   - Submit button
4. AJAX submission to mark attendance
5. Visual confirmation of submission
6. Tests for:
   - Correct student list for event
   - Attendance marking
   - Mobile responsiveness

Include offline capability planning for future.
```

### Step 15: Attendance Notifications

```text
Implement the 15-minute attendance notification system.

Create notification system:
1. Background job infrastructure (using Minion)
2. Registry::Job::AttendanceCheck that:
   - Runs every minute
   - Finds events starting in last 15 minutes
   - Checks for missing attendance records
   - Sends notifications for missing students
3. Registry::Notification with:
   - send_email method
   - send_in_app method
   - Notification templates
4. Teacher reminder if no attendance taken
5. Tests for:
   - Job scheduling
   - Notification triggering
   - Email delivery

Add notification preferences to user settings.
```

### Step 16: Parent Communication System

```text
Build one-way communication system from staff to parents.

Implement messaging:
1. Create messages table with:
   - sender_id, recipient_ids
   - subject, body
   - message_type (announcement, update, emergency)
   - scope (program, session, child-specific)
2. Registry::DAO::Message with:
   - send_message method
   - get_messages_for_parent method
3. UI for Morgan to compose messages:
   - Select recipients by program/session
   - Message templates
   - Schedule for later sending
4. Parent message view in their dashboard
5. Tests for message creation and delivery

Plan for two-way communication in architecture.
```

### Step 17: Waitlist Automation

```text
Implement automatic waitlist progression.

Add waitlist processing:
1. Registry::Job::ProcessWaitlist that:
   - Monitors enrollment cancellations
   - Promotes next waitlist entry
   - Creates payment deadline
   - Sends notification email
2. Registry::Job::WaitlistExpiration that:
   - Runs before each event
   - Expires unpaid waitlist offers
   - Promotes next person
3. Parent interface to accept/decline offer
4. Update enrollment counts in real-time
5. Tests for:
   - Automatic progression
   - Deadline enforcement
   - Multi-step progression

Include waitlist position in parent dashboard.
```

## Integration Phase

### Step 18: Parent Dashboard Integration

```text
Create unified parent dashboard bringing together all parent features.

Build parent dashboard:
1. Registry::Controller::ParentDashboard
2. Dashboard showing:
   - Enrolled programs for all children
   - Upcoming events calendar view
   - Recent attendance records
   - Messages from staff
   - Waitlist positions
   - Quick actions (drop, contact)
3. Mobile-responsive design
4. HTMX for dynamic updates
5. Tests for data aggregation and display

This ties together enrollment, attendance, and communication.
```

### Step 19: Admin Dashboard for Morgan

```text
Create comprehensive admin dashboard for program managers.

Build admin dashboard:
1. Registry::Controller::AdminDashboard  
2. Dashboard sections:
   - Program overview (enrollments, capacity)
   - Today's events with attendance status
   - Recent notifications
   - Waitlist management
   - Quick actions (message parents, export)
3. Real-time updates using HTMX
4. Data visualization for enrollment trends
5. Tests for:
   - Permission checking
   - Data accuracy
   - Performance with large datasets

Include role-based access control.
```

### Step 20: End-to-End Testing and Polish

```text
Perform comprehensive integration testing and polish.

Final integration:
1. Write end-to-end tests covering:
   - Complete parent journey from discovery to enrollment
   - Morgan's program creation and management
   - Attendance flow from marking to notifications
   - Payment and waitlist progression
2. Performance optimization:
   - Add database indexes
   - Implement caching where appropriate
   - Optimize N+1 queries
3. Polish UI/UX:
   - Loading states
   - Error handling
   - Success confirmations
4. Security audit:
   - Input validation
   - SQL injection prevention
   - XSS protection
5. Documentation updates

This ensures production readiness.
```

## Implementation Notes

Each prompt:
1. Builds on previous work
2. Includes comprehensive tests
3. Integrates immediately with existing code
4. Follows Registry's patterns (Object::Pad, Mojolicious, workflow system)
5. Maintains multi-tenant isolation
6. Uses HTMX for dynamic behavior

The progression ensures:
- No orphaned code
- Continuous integration
- Incremental complexity
- Early user value delivery