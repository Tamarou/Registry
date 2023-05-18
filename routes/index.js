import {view} from "primate";

export default {
  get(request) {
    return view('index.htmx')
  },
};
