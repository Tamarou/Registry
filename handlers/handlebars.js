import {Path} from "runtime-compat/fs";
import Handlebars from "handlebars";

const loadComponent = async (file) => {
  try {
    return await file.read();
  } catch (error) {
    throw new Error(`cannot load component at ${file.name}`);
  }
};

const getBody = async (app, props, file) => {
  const template = Handlebars.compile(await loadComponent(file));
  const body = template(props);
  return props.partial ? body : app.render({body});
};

const handler = path => (name, props, options) =>
  async app => {
    return [await getBody(app, props, path.join(name).file), { status: 200 }];
  };

export default ({} = {}) => ({
  name: "@tamarou/registry/handlebars",
  register(app, next) {
    app.register("handlebars", handler(app.paths.components));
    return next(app);
  },
});
