# Events and Sessions Architecture

## Overview

This document outlines the architectural design for the Events and Sessions
components of the Registry application, with a focus on how they support summer
camps and other educational programs.

## Core Concepts

### Events

An Event represents the smallest atomic unit of instruction with the following
characteristics:
- Takes place at a specific **time** and **location**
- Has a specific **duration**
- Is taught by **one or more teachers**
- Optionally follows a specific **project** (curriculum)
- Has a student **roster** with a maximum **capacity**

Events are the atomic units of scheduling in Registry. They represent
individual meetings or classes that occur at a specific point in time.

### Sessions

An Session represents a collection of related Events grouped and sold as a unit:
- Has a descriptive **name** and **slug**
- Includes one or more **sessions**
- Has a **purchase price**
- May have **start date** and **end date** derived from its sessions
- Has a **status** for publication control

Sessions are the unit of registration and purchase in Registry. When a parent
enrolls a student, they are purchasing a Session, which may contain one or
multiple Events.

### Relationships

The relationship between Events and Sessions is one-to-many:
- A Session contains one or more Events
- An Event belongs to one Session

This relationship is modeled through the `session_events` junction table.

## Summer Camp Model

Summer camps are implemented using this architecture as follows:

1. **Camp Week (Sesion)**
   - Represents the entire summer camp offering (e.g., "Science Camp Week 1")
   - Has a single purchase price
   - Has start and end dates derived from its sessions

2. **Camp Days (Event)**
   - Represent individual days of the camp
   - Each has its own time, location, and teachers
   - Each has its own capacity limitations
   - Each maintains its own student roster

3. **Registration**
   - Parents register for the entire Session (camp)
   - Registration automatically includes all associated Events (days)
   - Pricing is attached to the Session, not individual Events

## Database Schema

### Sessions Table
```
events
├── id (uuid, PK)
├── time (timestamp)
├── duration (integer, minutes)
├── location_id (uuid, FK)
├── project_id (uuid, FK, optional)
├── session_id (uuid, FK)
├── capacity (integer)
├── metadata (jsonb)
├── notes (text)
├── created_at (timestamp)
└── updated_at (timestamp)
```

### Session Teachers Junction Table
```
event_teachers
├── id (uuid, PK)
├── event_id (uuid, FK)
├── teacher_id (uuid, FK)
├── created_at (timestamp)
└── updated_at (timestamp)
```

### Events Table
```
sessions
├── id (uuid, PK)
├── name (text)
├── slug (text)
├── status (text)
├── metadata (jsonb)
├── notes (text)
├── created_at (timestamp)
└── updated_at (timestamp)
```

### Pricing Table
```
pricing
├── id (uuid, PK)
├── session_id (uuid, FK)
├── amount (decimal)
├── currency (text)
├── early_bird_amount (decimal)
├── early_bird_cutoff_date (date)
├── sibling_discount (decimal)
├── metadata (jsonb)
├── created_at (timestamp)
└── updated_at (timestamp)
```

### Enrollments Table
```
enrollments
├── id (uuid, PK)
├── session_id (uuid, FK)
├── student_id (uuid, FK)
├── status (text)
├── metadata (jsonb)
├── created_at (timestamp)
└── updated_at (timestamp)
```

## Common Usage Patterns

### Creating a Summer Camp

1. Create an Session
2. Create multiple Events, one for each day of the camp
3. Associate the Events with the Session via the `session_events` table
4. Create a Pricing record for the Session

### Enrolling in a Camp

1. User selects an Event (camp)
2. System checks availability based on Sessions' capacities
3. User completes registration for the Event
4. System creates an Enrollment record linking the student to the Event
5. Student is automatically enrolled in all Sessions associated with the Event

### Finding Available Camps

1. Query Sessions with status `published`
2. Filter by date range, if applicable
3. Check available capacity across all associated Events
4. Return matching Sessions with their associated Events

## Implementation Considerations

### Capacity Management

When managing capacity:
- Event capacity represents physical limitations of a specific day/location
- Enrollment should check capacity for each Event before confirming
- System may need to handle waitlists if some Event have different capacities

### Date Handling

For date-based operations:
- Session date range is derived from the earliest and latest Event dates
- System should provide helper methods to calculate these derived properties
- When displaying Sessions, date ranges should be calculated dynamically or cached

### Status Workflow

Events follow a publication status workflow:
- `draft`: Initial creation, not visible to parents
- `published`: Open for registration
- `closed`: Registration closed

### Pricing Attachment

Pricing is attached to Sessions, not individual Events:
- An Session has exactly one Pricing record
- The price covers all Events in the Session
- Special pricing types (early bird, sibling discounts) are defined at the
  Session level

## Data Access Layer

The DAO (Data Access Object) classes provide an object-oriented interface to
these database tables:

- `Registry::DAO::Event`: Represents individual scheduled meetings/classes
- `Registry::DAO::Session`: Represents collections of events sold as a unit
- `Registry::DAO::Pricing`: Represents pricing structures for sessions

These classes provide methods for:
- Creating and updating records
- Finding and filtering records
- Managing relationships between entities
- Helper methods for common operations

### Example: Summer Camp Implementation

```perl
# Create a summer camp event
my $camp_event = $dao->create('Registry::DAO::Event', {
    name => 'Science Camp Week 1',
    slug => 'science-camp-week-1',
    event_type => 'camp',
    status => 'draft'
});

# Create individual camp day sessions
my @camp_sessions;
for my $day (1..5) {
    my $date = sprintf("2025-06-%d", 14 + $day);
    push @camp_sessions, $dao->create('Registry::DAO::Session', {
        time => "$date 09:00:00",
        duration => 480, # 8 hours in minutes
        location_id => $location_id,
        project_id => $project_id,
        session_type => 'camp_day',
        capacity => 20
    });

    # Add teachers to the session
    $dao->create('Registry::DAO::SessionTeacher', {
        session_id => $camp_sessions[-1]->id,
        teacher_id => $main_teacher_id
    });
    $dao->create('Registry::DAO::SessionTeacher', {
        session_id => $camp_sessions[-1]->id,
        teacher_id => $assistant_teacher_id
    });
}

# Associate sessions with the event
$camp_event->add_sessions($dao->db, map { $_->id } @camp_sessions);

# Set pricing for the event
$dao->create('Registry::DAO::Pricing', {
    event_id => $camp_event->id,
    amount => 299.99,
    currency => 'USD',
    early_bird_amount => 249.99,
    early_bird_cutoff_date => '2025-04-01',
    sibling_discount => 10.00
});

# Publish the event
$camp_event->publish($dao->db);
```
