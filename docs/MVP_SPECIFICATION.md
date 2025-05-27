# Registry MVP Specification

## Executive Summary

This document outlines the minimum viable product (MVP) specifications for Registry, an educational platform for after-school programs. The MVP focuses on two primary user personas: Nancy (parent) and Morgan (program developer/advanced user), enabling program discovery, enrollment, creation, and management.

## Core User Personas

### Nancy - Parent
- **Primary Need**: Easy discovery and enrollment of children in after-school programs
- **Key Pain Point**: Current system shows programs at locations their child cannot attend

### Morgan - Program Developer/Advanced User
- **Primary Need**: Efficient program creation and management across multiple locations
- **Key Pain Point**: Managing complex schedules across multiple schools with different teachers

## Key Features

### 1. Location-Based Program Discovery

#### Requirements
- Public school landing pages (e.g., `/school/lincoln-elementary`)
- Show only current tenant's programs at that location
- Display essential information:
  - Program name and description
  - Dates (start/end)
  - Price
  - Available spots
- Direct link from program to enrollment workflow

#### Technical Notes
- Leverage existing location infrastructure (locations can already represent schools)
- Use location slug for URL routing
- Filter programs by tenant and location

### 2. Multi-Child Enrollment Workflow

#### Flow
1. Parent arrives at school landing page
2. Clicks on program → enrollment workflow starts
3. Account creation/login (via continuation)
4. Enter first child information
5. Select sessions (based on program type rules)
6. Option to "Add another child" (pre-fills shared info)
7. Payment for all children
8. Confirmation

#### Program Type Rules
- **After-school**: All children must attend same session
- **Summer camp**: Children can attend different sessions

#### Payment Integration
- Stripe integration for payment processing
- Support upfront payment (MVP requirement)
- Subscription billing (future capability)

### 3. PriceOps-Style Pricing System

#### MVP Features
- Multiple pricing plans per session
- Early bird pricing with cutoff dates
- Sibling/family discounts
- Payment plan options (upfront vs installments)

#### Future Considerations
- Scholarships/financial aid
- Promotional codes
- Dynamic pricing
- Bundle pricing

### 4. Program Creation Workflow

#### Two Workflows
1. **Create New Program**
   - Select program type (pre-configured: after-school, summer camp)
   - Define curriculum details
   - Set age/grade requirements
   - Specify staff requirements (number needed)
   - Define session timeframe pattern (custom patterns supported)

2. **Add Program to Location**
   - Select existing program
   - Choose location(s)
   - Set location-specific details:
     - Capacity
     - Schedule (with pre-populated standard times)
     - Pricing
     - Teacher assignments

#### Program Types Configuration
Pre-configured types with:
- Standard start times (e.g., 3pm Mon-Fri, 2pm Wed)
- Enrollment rules (same/different sessions for siblings)
- Scheduling patterns
- Stored in session_type field

### 5. Session and Event Management

#### Data Model Clarification
- **Session**: Collection of related events sold as unit (e.g., "Spring Robotics")
- **Event**: Single meeting at specific location/time
- **Project**: Curriculum content

#### Morgan's Mental Model
- Thinks in terms of curriculum weeks, not individual events
- Example: "Week 1 content" taught at 10 locations, not 60 separate events
- UI should reflect this curriculum-first approach

#### Scheduling Features
- Standard times by day (3pm regular, 2pm Wednesday)
- Teacher conflict checking (block with override)
- Travel time validation between locations
- Bulk event creation across locations

### 6. Attendance Tracking

#### Requirements
- Teachers mark present/absent (mobile-friendly)
- Real-time alerts:
  - Morgan notified of missing students within 15 minutes
  - Teacher reminder if attendance not taken
- Parent notifications (configurable)
- Simple present/absent (no reasons required)

### 7. Communication System

#### MVP: One-Way Communication
- Program updates (schedule changes, cancellations)
- Child-specific messages
- General announcements
- Emergency notifications
- Email and in-app notifications

#### Future: Channel-Specific Two-Way

### 8. Waitlist Management

#### Automatic Progression
- Parents can join waitlist during enrollment
- First-come-first-served default (Morgan can reorder)
- When spot opens:
  - Automatically assigned to next person
  - "Please pay" email sent
  - Must pay before next event or spot moves to next person
- Parents can decline spot
- Single location waitlist only

### 9. Drops and Transfers

#### Manual Process
- Drops before session starts: Parent self-service
- Drops after session starts: Requires Morgan
- Transfers: Require Morgan (very rare)
- No automatic refunds (Morgan can override)

## Technical Implementation Notes

### Database Updates Needed

1. **Pricing Table Redesign**
   - Support for multiple pricing plans
   - Payment plan configurations
   - Discount rules

2. **Program Type Definitions**
   - Configuration table for program types
   - Enrollment rules
   - Standard scheduling patterns

3. **Attendance Tracking**
   - New attendance table
   - Link to events and enrollments

4. **Waitlist Management**
   - Waitlist table with position tracking
   - Automated status transitions

5. **Communication System**
   - Messages table
   - Notification preferences
   - Delivery status tracking

### Workflow Updates

1. **School Landing Page Workflow**
   - New public-facing workflow
   - No authentication required
   - Program listing and filtering

2. **Enhanced Enrollment Workflow**
   - Account creation continuation
   - Multi-child support
   - Program-specific rules engine
   - Payment integration

3. **Program Management Workflows**
   - Program creation
   - Location assignment
   - Bulk event generation

4. **Attendance Workflow**
   - Teacher mobile interface
   - Real-time notification system

### Integration Points

1. **Payment Processor (Stripe)**
   - Payment collection
   - Subscription management
   - Refund processing

2. **Notification System**
   - Email service
   - In-app notifications
   - SMS (future)

## Success Metrics

1. **Parent Experience**
   - Time to enroll < 10 minutes
   - No wrong-location enrollments
   - Clear program information

2. **Program Manager Efficiency**
   - Bulk program deployment across locations
   - Automated attendance alerts
   - Simplified waitlist management

3. **System Reliability**
   - Accurate attendance tracking
   - Reliable payment processing
   - Timely notifications

## Development Priorities

### Phase 1: Core Enrollment
1. School landing pages
2. Basic enrollment workflow
3. Payment integration

### Phase 2: Program Management
1. Program creation workflows
2. Multi-location deployment
3. Teacher assignment

### Phase 3: Operations
1. Attendance tracking
2. Communication system
3. Waitlist management

This specification provides a comprehensive roadmap for implementing the Registry MVP focused on delivering immediate value to parents seeking programs and program managers running them.