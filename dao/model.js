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
    image;
    preferred_name;
    age;
    contacts;
    notes;
    constructor(args) { Object.assign(this, args) }
};

export class Event {
    id = randomUUID();
    name;
    image;
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
    image;
    name;
    description;
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
