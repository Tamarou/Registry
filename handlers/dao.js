import {dao} from "../dao/index.js";

export default ({} = {}) => ({
    name: "@tamarou/registry/dao",
    handle(request, next) {
      return next({ ...request, dao });
    },
    // TODO add a route() handler too for transactions
});
