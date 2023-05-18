export const dao = {
  get_locations() {
    return Array(5).fill().map((_, id) => ({
      id,
      name: `Location ${id}`,
      address: "Here",
      notes: "C#, Bb"
    }));
  },
};

