# Validation System Architecture

## Overview
The Registry validation system is designed to support educational program
management while remaining accessible to non-technical users. It combines
outcome definitions with a template-based validation system that allows program
managers to implement complex business rules without writing code.

## Core Concepts

### 1. Outcome Definitions
Outcome definitions contain the basic field-level validations as part of their
structure. These include:

```json
{
  "name": "Student Registration",
  "fields": [
    {
      "id": "parentPhone",
      "type": "phone",
      "label": "Parent Phone Number",
      "required": true,
      "format": "US"
    },
    {
      "id": "studentGrade",
      "type": "select",
      "label": "Grade Level",
      "required": true,
      "options": ["K", "1", "2", "3", "4", "5"],
      "constraints": {
        "min": "K",
        "max": "5"
      }
    }
  ]
}
```

Field-level validations handle:
- Required fields
- Data type validation
- Format requirements
- Range constraints
- Option lists

### 2. Business Logic Validations
Complex validations are handled through a template-based system with three levels:

#### Level 1: Basic Validation Templates
Pre-built templates for common educational program needs:
- Class Management
  * Maximum class size checks
  * Grade level restrictions
- Safety Requirements
  * Emergency contact verification
  * Medical information requirements
- Scheduling
  * Time conflict detection
  * Prerequisite verification

#### Level 2: Validation Builder
"If-this-then-that" style interface for creating custom rules:
```
IF [condition] THEN [action]
```

Supported conditions:
- Numeric comparisons (equals, less than, greater than)
- Text matching
- Date/time checks
- Enrollment status
- Student attributes

Supported actions:
- Show message
- Prevent enrollment
- Start waitlist
- Send notification
- Mark requirement incomplete

#### Level 3: Program Templates
Complete validation sets for common program types:
- After-School Classes
- Summer Camps
- Enrichment Series
- Workshops

### 3. Implementation Details

#### Database Schema
```sql
-- Outcome Definitions
CREATE TABLE outcome_definitions (
    id UUID PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    fields JSONB NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Validation Templates
CREATE TABLE validation_templates (
    id UUID PRIMARY KEY,
    category TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    parameters JSONB NOT NULL,
    implementation_key TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Program Templates
CREATE TABLE program_templates (
    id UUID PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    validation_rules JSONB NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
```

#### Rule Execution
1. Field validations are checked first (from outcome definition)
2. Template-based validations are executed in priority order
3. Program-level validations are checked last
4. All validation results are collected and returned together

### 4. User Interface Guidelines

#### Template Selection
- Organized in categories matching educational concepts
- Uses natural language descriptions
- Provides clear examples
- Shows preview of validation behavior

#### Configuration Interface
- Simple forms for basic templates
- Visual builder for custom rules
- Real-time preview and testing
- Clear error messages and guidance

#### Program Setup
- Start with program template selection
- Guide through validation configuration
- Allow template customization
- Provide validation testing tools

### 5. Extension Process

For new validation needs:
1. Users request new validation template
2. Development team implements template
3. Template is added to system
4. Template becomes available to all users

Benefits:
- No coding required from users
- System grows with user needs
- Maintains consistency
- Leverages common patterns

### 6. Future Considerations

Potential enhancements:
- Machine learning for validation suggestions
- Advanced rule combinations
- Custom validation marketplace
- Integration with external validation services

## Technical Implementation Notes

### Code Organization
```perl
Registry::DAO::OutcomeDefinition  # Handles outcome definitions
Registry::DAO::ValidationTemplate # Manages validation templates
Registry::DAO::ProgramTemplate    # Manages program templates
Registry::Validation::Engine      # Executes validation rules
Registry::Validation::Builder     # Handles rule building interface
```

### Performance Considerations
- Cache commonly used templates
- Batch validation where possible
- Prioritize rule execution order
- Monitor validation timing

### Security Considerations
- Validate all user inputs
- Enforce role-based access control
- Audit validation changes
- Prevent infinite loops in custom rules
