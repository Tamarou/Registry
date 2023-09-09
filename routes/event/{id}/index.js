import {view} from "primate";

export default {
  get({headers, path, dao}) {
    const id = path.get('id');
    const partial = headers.get("hx-request");
    const event = dao.get_event(id);
    return view('event/index.handlebars', {event, partial})
  },
};
