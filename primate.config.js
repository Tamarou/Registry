import dao from "./handlers/dao.js";
import handlebars from "./handlers/handlebars.js";
import htmx from "@primate/htmx";

export default {
  modules: [htmx(), dao(), handlebars()],
  http: {
    host: '0.0.0.0',
    port: 10000,
    csp: {
      "default-src": "'self' fonts.googleapis.com",
      "font-src": "fonts.googleapis.com",
      "img-src": "'self' live.staticflickr.com",
      "object-src": "'none'",
      "frame-ancestors": "'none'",
      "form-action": "'self'",
      "base-uri": "'self'",
      "script-src": "'self' cdnjs.cloudflare.com",
      "style-src":"'self' cdnjs.cloudflare.com fonts.googleapis.com"
    },
  },
};
