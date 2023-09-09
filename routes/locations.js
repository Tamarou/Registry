import {view} from "primate";

export default {
  get({headers, dao}) {
    const partial = headers.get("hx-request");
    const locations = dao.get_locations();
    return view('locations.handlebars', {locations, partial})
  },
};
