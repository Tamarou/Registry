export default {"1":function(container,depth0,helpers,partials,data) {
    var stack1, helper, alias1=depth0 != null ? depth0 : (container.nullContext || {}), alias2=container.hooks.helperMissing, alias3="function", alias4=container.escapeExpression, lookupProperty = container.lookupProperty || function(parent, propertyName) {
        if (Object.prototype.hasOwnProperty.call(parent, propertyName)) {
          return parent[propertyName];
        }
        return undefined
    };

  return "    <div class=\"card medium\">\n        <div class=\"card-image\">\n            <img class=\"activator\" src=\""
    + alias4(((helper = (helper = lookupProperty(helpers,"image") || (depth0 != null ? lookupProperty(depth0,"image") : depth0)) != null ? helper : alias2),(typeof helper === alias3 ? helper.call(alias1,{"name":"image","hash":{},"data":data,"loc":{"start":{"line":4,"column":40},"end":{"line":4,"column":49}}}) : helper)))
    + "\" />\n        </div>\n        <span class=\"card-title\">"
    + alias4(((helper = (helper = lookupProperty(helpers,"name") || (depth0 != null ? lookupProperty(depth0,"name") : depth0)) != null ? helper : alias2),(typeof helper === alias3 ? helper.call(alias1,{"name":"name","hash":{},"data":data,"loc":{"start":{"line":6,"column":33},"end":{"line":6,"column":41}}}) : helper)))
    + " <i class=\"material-icons right\">more_vert</i></span>\n        <div class=\"card-content\">\n            <p class=\"location\">"
    + alias4(container.lambda(((stack1 = (depth0 != null ? lookupProperty(depth0,"location") : depth0)) != null ? lookupProperty(stack1,"name") : stack1), depth0))
    + "</p>\n        </div>\n        <div class=\"card-reveal\">\n            <span class=\"card-title\">"
    + alias4(((helper = (helper = lookupProperty(helpers,"name") || (depth0 != null ? lookupProperty(depth0,"name") : depth0)) != null ? helper : alias2),(typeof helper === alias3 ? helper.call(alias1,{"name":"name","hash":{},"data":data,"loc":{"start":{"line":11,"column":37},"end":{"line":11,"column":45}}}) : helper)))
    + " <i class=\"material-icons right\">close</i></span>\n            <p class=\"description\">"
    + alias4(((helper = (helper = lookupProperty(helpers,"description") || (depth0 != null ? lookupProperty(depth0,"description") : depth0)) != null ? helper : alias2),(typeof helper === alias3 ? helper.call(alias1,{"name":"description","hash":{},"data":data,"loc":{"start":{"line":12,"column":35},"end":{"line":12,"column":50}}}) : helper)))
    + "</p>\n        </div>\n        <div class=\"card-action text-darken-2\">\n            <a class=\"waves-effect btn activator\" href=\"#\">View</a>\n            <a class=\"waves-effect btn\" href=\"/event/"
    + alias4(((helper = (helper = lookupProperty(helpers,"id") || (depth0 != null ? lookupProperty(depth0,"id") : depth0)) != null ? helper : alias2),(typeof helper === alias3 ? helper.call(alias1,{"name":"id","hash":{},"data":data,"loc":{"start":{"line":16,"column":53},"end":{"line":16,"column":59}}}) : helper)))
    + "/register\">Register</a>\n        </div>\n    </div>\n";
},"compiler":[8,">= 4.3.0"],"main":function(container,depth0,helpers,partials,data) {
    var stack1, lookupProperty = container.lookupProperty || function(parent, propertyName) {
        if (Object.prototype.hasOwnProperty.call(parent, propertyName)) {
          return parent[propertyName];
        }
        return undefined
    };

  return ((stack1 = lookupProperty(helpers,"each").call(depth0 != null ? depth0 : (container.nullContext || {}),(depth0 != null ? lookupProperty(depth0,"events") : depth0),{"name":"each","hash":{},"fn":container.program(1, data, 0),"inverse":container.noop,"data":data,"loc":{"start":{"line":1,"column":0},"end":{"line":19,"column":9}}})) != null ? stack1 : "")
    + "<script>\n// external js: masonry.pkgd.js, imagesloaded.pkgd.js\n\n// init Masonry\nvar grid = document.querySelector('.container');\n\nvar msnry = new Masonry( grid, {\n  itemSelector: '.card',\n  columnWidth: 200,\n  gutter: 10,\n  fitWidth: true\n});\n\nimagesLoaded( grid, { background: true } ).on( 'done', function() {\n  // layout Masonry after each image loads\n  msnry.layout();\n});\n</script>\n";
},"useData":true}