import { Event, Location } from "./model.js";

export const dao = {
  get_event(id) {
    new Event({
            name: `${id} Event`,
            image: 'https://live.staticflickr.com/65535/51795829956_c2aefe2a07_n.jpg',
            description:
              "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Turpis egestas pretium aenean pharetra magna ac. Fermentum posuere urna nec tincidunt praesent semper feugiat nibh sed.",
            sessions: [],
            roster: [],
            notes:
              "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Turpis egestas pretium aenean pharetra magna ac. Fermentum posuere urna nec tincidunt praesent semper feugiat nibh sed.",
    });
  },
  get_events() {
    return Array(5)
      .fill()
      .map(
        (_, id) =>
          new Event({
            name: `${id} Event`,
            image: 'https://live.staticflickr.com/65535/51795829956_c2aefe2a07_n.jpg',
            description:
              "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Turpis egestas pretium aenean pharetra magna ac. Fermentum posuere urna nec tincidunt praesent semper feugiat nibh sed.",
            sessions: [],
            roster: [],
            notes:
              "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Turpis egestas pretium aenean pharetra magna ac. Fermentum posuere urna nec tincidunt praesent semper feugiat nibh sed.",
          })
      );
  },

  get_locations() {
    return Array(5)
      .fill()
      .map(
        (_, id) =>
          new Location({
            name: `${id} Location`,
            address: "Here",
            notes:
              "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Turpis egestas pretium aenean pharetra magna ac. Fermentum posuere urna nec tincidunt praesent semper feugiat nibh sed.",
          })
      );
  },
};
