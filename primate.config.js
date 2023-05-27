import dao from "./handlers/dao.js";
import handlebars from "./handlers/handlebars.js";

export default {
  modules: [dao(), handlebars()],
  http: {
    host: "0.0.0.0",
    port: 10000,
    csp: {
      "default-src": "'self'",
      "font-src": "fonts.googleapis.com fonts.gstatic.com",
      "img-src": "'self' live.staticflickr.com",
      "object-src": "'none'",
      "frame-ancestors": "'none'",
      "form-action": "'self'",
      "base-uri": "'self'",
      "script-src": "'self' 'unsafe-inline' cdnjs.cloudflare.com unpkg.com",
      "style-src":
        "'self' 'unsafe-inline' cdnjs.cloudflare.com fonts.googleapis.com fonts.gstatic.com",
    },
  },
};
