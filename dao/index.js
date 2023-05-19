export const dao = {
  get_events() {
    return Array(5)
      .fill()
      .map((_, id) => ({
        id,
        name: `Event ${id}`,
        description:
          "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Turpis egestas pretium aenean pharetra magna ac. Fermentum posuere urna nec tincidunt praesent semper feugiat nibh sed.",
        sessions: [],
        location: {
          id,
          name: `Location ${id}`,
          address: "Here",
          notes: "C#, Bb",
        },
      }));
  },
  get_locations() {
    return Array(5)
      .fill()
      .map((_, id) => ({
        id,
        name: `Location ${id}`,
        address: "Here",
        notes: "C#, Bb",
      }));
  },
};
