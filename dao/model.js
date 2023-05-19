import {randomUUID } from "crypto";

export class Company {
    id = randomUUID();
    name;
    contacts;
    notes;
    constructor(args) { Object.assign(this, args) }
};

export class Person {
    id = randomUUID();
    preferred_name;
    age;
    contacts;
    notes;
    constructor(args) { Object.assign(this, args) }
};

export class Event {
    id = randomUUID();
    description;
    sessions;
    roster;
    notes;
    constructor(args) { Object.assign(this, args) }
};

export class Session {
    id = randomUUID();
    start_datetime;
    duration;
    roster;
    notes;
    constructor(args) { Object.assign(this, args) }
};

export class Location {
    id = randomUUID();
    name;
    addresss;
    contacts;
    notes;
    constructor(args) { Object.assign(this, args) }
};

export class Roster {
    id = randomUUID();
    participants;
    constructor(args) { Object.assign(this, args) }
}
