const fs = require('node:fs');
const path = require('node:path');
const nunjucks = require('nunjucks');

function renderTemplate(source, destination, values) {
  const environment = new nunjucks.Environment(null, {
    autoescape: false, throwOnUndefined: true,
    tags: { variableStart: '${{', variableEnd: '}}' }
  });
  environment.addFilter('dump', value => JSON.stringify(value));
  for (const entry of fs.readdirSync(source, { withFileTypes: true })) {
    if (entry.isSymbolicLink()) throw new Error('Skeleton symlinks are forbidden');
    const target = path.join(destination, entry.name);
    if (entry.isDirectory()) {
      fs.mkdirSync(target, { recursive: true });
      renderTemplate(path.join(source, entry.name), target, values);
    } else {
      fs.mkdirSync(destination, { recursive: true });
      fs.writeFileSync(target, environment.renderString(fs.readFileSync(path.join(source, entry.name), 'utf8'), { values }));
    }
  }
}
if (require.main === module) {
  renderTemplate(process.argv[2], process.argv[3], JSON.parse(process.argv[4]));
}
module.exports = { renderTemplate };
