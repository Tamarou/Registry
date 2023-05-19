# Registry

This is port of the unfinished Super Awesome Cool Registry application to PrimateJS / Javascript.

## Getting Started

```
# install dependencies
brew install postgresql
brew install sqitch
npm install

# load the database
createdb registry
sqitch deploy

# now run the dev server
npx primate
```

## Running Tests

There currently are no tests, that's bad.

## Data Model

### Company

A company that wants to track sessions and their rosters.

### Person

A Natural Person, they may have a relationship to one or more other people.
They may have a relationship to a login.

### Roster

A group of people associated with a Session, each person may have one or more
roles in the roster (Student, Teacher, Facilitator etc.)

### Event

One or More sessions associated with a location and roster

### Session

Represents a specific time interval or period within the schedule. It may
include attributes such as the start date + time, duration, and any other
relevant details related to the time slot.

### Location

A physical location where Session Periods may take place

## Advanced Data Model

### Login

A set of credentials for a Person to access the system.

### Resource

A constrained resource (equipment, materials, etc) that is required for a given session
