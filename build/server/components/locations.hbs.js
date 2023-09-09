export default {"1":function(container,depth0,helpers,partials,data) {
    var helper, alias1=depth0 != null ? depth0 : (container.nullContext || {}), alias2=container.hooks.helperMissing, alias3="function", alias4=container.escapeExpression, lookupProperty = container.lookupProperty || function(parent, propertyName) {
        if (Object.prototype.hasOwnProperty.call(parent, propertyName)) {
          return parent[propertyName];
        }
        return undefined
    };

  return "    <div class=\"card medium\">\n        <div class=\"card-image\">\n            <img class=\"activator\" src=\"https://live.staticflickr.com/65535/51795829956_c2aefe2a07_n.jpg\" />\n        </div>\n        <span class=\"card-title\">"
    + alias4(((helper = (helper = lookupProperty(helpers,"name") || (depth0 != null ? lookupProperty(depth0,"name") : depth0)) != null ? helper : alias2),(typeof helper === alias3 ? helper.call(alias1,{"name":"name","hash":{},"data":data,"loc":{"start":{"line":6,"column":33},"end":{"line":6,"column":41}}}) : helper)))
    + " <i class=\"material-icons right\">more_vert</i></span>\n        <div class=\"card-content\"></div>\n        <div class=\"card-reveal\">\n            <span class=\"card-title\">"
    + alias4(((helper = (helper = lookupProperty(helpers,"name") || (depth0 != null ? lookupProperty(depth0,"name") : depth0)) != null ? helper : alias2),(typeof helper === alias3 ? helper.call(alias1,{"name":"name","hash":{},"data":data,"loc":{"start":{"line":9,"column":37},"end":{"line":9,"column":45}}}) : helper)))
    + " <i class=\"material-icons right\">close</i></span>\n            <address>"
    + alias4(((helper = (helper = lookupProperty(helpers,"address") || (depth0 != null ? lookupProperty(depth0,"address") : depth0)) != null ? helper : alias2),(typeof helper === alias3 ? helper.call(alias1,{"name":"address","hash":{},"data":data,"loc":{"start":{"line":10,"column":21},"end":{"line":10,"column":32}}}) : helper)))
    + "</address>\n            <p class=\"notes\">"
    + alias4(((helper = (helper = lookupProperty(helpers,"notes") || (depth0 != null ? lookupProperty(depth0,"notes") : depth0)) != null ? helper : alias2),(typeof helper === alias3 ? helper.call(alias1,{"name":"notes","hash":{},"data":data,"loc":{"start":{"line":11,"column":29},"end":{"line":11,"column":38}}}) : helper)))
    + "</p>\n        </div>\n        <div class=\"card-action text-darken-2\">\n            <a href=\"/location/"
    + alias4(((helper = (helper = lookupProperty(helpers,"id") || (depth0 != null ? lookupProperty(depth0,"id") : depth0)) != null ? helper : alias2),(typeof helper === alias3 ? helper.call(alias1,{"name":"id","hash":{},"data":data,"loc":{"start":{"line":14,"column":31},"end":{"line":14,"column":37}}}) : helper)))
    + "\">Events at Location</a>\n        </div>\n    </div>\n";
},"compiler":[8,">= 4.3.0"],"main":function(container,depth0,helpers,partials,data) {
    var stack1, lookupProperty = container.lookupProperty || function(parent, propertyName) {
        if (Object.prototype.hasOwnProperty.call(parent, propertyName)) {
          return parent[propertyName];
        }
        return undefined
    };

  return ((stack1 = lookupProperty(helpers,"each").call(depth0 != null ? depth0 : (container.nullContext || {}),(depth0 != null ? lookupProperty(depth0,"locations") : depth0),{"name":"each","hash":{},"fn":container.program(1, data, 0),"inverse":container.noop,"data":data,"loc":{"start":{"line":1,"column":0},"end":{"line":17,"column":9}}})) != null ? stack1 : "")
    + "<script>\n// external js: masonry.pkgd.js, imagesloaded.pkgd.js\n\n// init Masonry\nvar grid = document.querySelector('.container');\n\nvar msnry = new Masonry( grid, {\n  itemSelector: '.card',\n  columnWidth: 200,\n  gutter: 10,\n  fitWidth: true\n});\n\nimagesLoaded( grid, { background: true } ).on( 'done', function() {\n  // layout Masonry after each image loads\n  msnry.layout();\n});\n</script>\n";
},"useData":true}