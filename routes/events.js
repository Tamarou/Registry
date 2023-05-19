import {view} from "primate";

export default {
  get({headers, dao}) {
    const partial = headers.get("hx-request");
    const events = dao.get_events();
    return view('events.handlebars', {events, partial})
  },
};
