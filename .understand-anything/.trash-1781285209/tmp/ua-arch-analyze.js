#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const inputPath = process.argv[2];
const outputPath = process.argv[3];

if (!inputPath || !outputPath) {
  console.error('Usage: node ua-arch-analyze.js <input.json> <output.json>');
  process.exit(1);
}

let input;
try {
  input = JSON.parse(fs.readFileSync(inputPath, 'utf8'));
} catch (e) {
  console.error('Failed to read/parse input:', e.message);
  process.exit(1);
}

const { fileNodes, importEdges, allEdges } = input;

// ─── A. Directory Grouping ───────────────────────────────────────────────────

function getFilePath(node) {
  return node.filePath || node.id.replace(/^[^:]+:/, '');
}

// Find common prefix
const allPaths = fileNodes.map(getFilePath);
function commonPrefix(paths) {
  if (!paths.length) return '';
  const parts = paths[0].split('/');
  let prefix = '';
  for (let i = 0; i < parts.length - 1; i++) {
    const candidate = parts.slice(0, i + 1).join('/') + '/';
    if (paths.every(p => p.startsWith(candidate))) {
      prefix = candidate;
    } else {
      break;
    }
  }
  return prefix;
}

const commonPfx = commonPrefix(allPaths);

function getDirectoryGroup(filePath) {
  let relative = filePath;
  if (commonPfx && filePath.startsWith(commonPfx)) {
    relative = filePath.slice(commonPfx.length);
  }
  const parts = relative.split('/');
  if (parts.length === 1) return '__root__';
  return parts[0];
}

const directoryGroups = {};
for (const node of fileNodes) {
  const fp = getFilePath(node);
  const group = getDirectoryGroup(fp);
  if (!directoryGroups[group]) directoryGroups[group] = [];
  directoryGroups[group].push(node.id);
}

// ─── B. Node Type Grouping ───────────────────────────────────────────────────

const nodeTypeGroups = {};
for (const node of fileNodes) {
  const t = node.type;
  if (!nodeTypeGroups[t]) nodeTypeGroups[t] = [];
  nodeTypeGroups[t].push(node.id);
}

// ─── C. Import Adjacency Matrix ──────────────────────────────────────────────

const nodeById = {};
for (const node of fileNodes) nodeById[node.id] = node;

const fanIn = {};
const fanOut = {};
for (const node of fileNodes) {
  fanIn[node.id] = 0;
  fanOut[node.id] = 0;
}

for (const edge of importEdges) {
  if (fanOut[edge.source] !== undefined) fanOut[edge.source]++;
  if (fanIn[edge.target] !== undefined) fanIn[edge.target]++;
}

// ─── D. Cross-Category Dependency Analysis ───────────────────────────────────

const crossCategoryMap = {};
for (const edge of allEdges) {
  const srcNode = nodeById[edge.source];
  const tgtNode = nodeById[edge.target];
  if (!srcNode || !tgtNode) continue;
  const key = `${srcNode.type}::${tgtNode.type}::${edge.type}`;
  crossCategoryMap[key] = (crossCategoryMap[key] || 0) + 1;
}
const crossCategoryEdges = Object.entries(crossCategoryMap).map(([key, count]) => {
  const [fromType, toType, edgeType] = key.split('::');
  return { fromType, toType, edgeType, count };
});

// ─── E. Inter-Group Import Frequency ─────────────────────────────────────────

function nodeGroup(nodeId) {
  const node = nodeById[nodeId];
  if (!node) return null;
  return getDirectoryGroup(getFilePath(node));
}

const interGroupMap = {};
for (const edge of importEdges) {
  const fromGroup = nodeGroup(edge.source);
  const toGroup = nodeGroup(edge.target);
  if (!fromGroup || !toGroup || fromGroup === toGroup) continue;
  const key = `${fromGroup}::${toGroup}`;
  interGroupMap[key] = (interGroupMap[key] || 0) + 1;
}
const interGroupImports = Object.entries(interGroupMap).map(([key, count]) => {
  const [from, to] = key.split('::');
  return { from, to, count };
}).sort((a, b) => b.count - a.count);

// ─── F. Intra-Group Import Density ───────────────────────────────────────────

const groupEdgeCounts = {};
const groupInternalEdges = {};
for (const group of Object.keys(directoryGroups)) {
  groupEdgeCounts[group] = 0;
  groupInternalEdges[group] = 0;
}

for (const edge of importEdges) {
  const fg = nodeGroup(edge.source);
  const tg = nodeGroup(edge.target);
  if (fg) groupEdgeCounts[fg] = (groupEdgeCounts[fg] || 0) + 1;
  if (tg && tg !== fg) groupEdgeCounts[tg] = (groupEdgeCounts[tg] || 0) + 1;
  if (fg && tg && fg === tg) {
    groupInternalEdges[fg] = (groupInternalEdges[fg] || 0) + 1;
  }
}

const intraGroupDensity = {};
for (const group of Object.keys(directoryGroups)) {
  const total = groupEdgeCounts[group] || 0;
  const internal = groupInternalEdges[group] || 0;
  intraGroupDensity[group] = {
    internalEdges: internal,
    totalEdges: total,
    density: total > 0 ? parseFloat((internal / total).toFixed(3)) : 0
  };
}

// ─── G. Directory Pattern Matching ───────────────────────────────────────────

const dirPatterns = {
  routes: 'api', api: 'api', controllers: 'api', endpoints: 'api', handlers: 'api',
  serializers: 'api', blueprints: 'api', routers: 'api', controller: 'api',
  services: 'service', core: 'service', lib: 'service', domain: 'service',
  logic: 'service', composables: 'service', mailers: 'service', jobs: 'service',
  channels: 'service', internal: 'service', signals: 'service',
  models: 'data', db: 'data', data: 'data', persistence: 'data',
  repository: 'data', entities: 'data', migrations: 'data', sql: 'data',
  database: 'data', schema: 'data', entity: 'data',
  components: 'ui', views: 'ui', pages: 'ui', ui: 'ui', layouts: 'ui', screens: 'ui',
  middleware: 'middleware', plugins: 'middleware', interceptors: 'middleware', guards: 'middleware',
  utils: 'utility', helpers: 'utility', common: 'utility', shared: 'utility',
  tools: 'utility', pkg: 'utility', templatetags: 'utility',
  config: 'config', constants: 'config', env: 'config', settings: 'config',
  management: 'config', commands: 'config',
  '__tests__': 'test', test: 'test', tests: 'test', spec: 'test', specs: 'test',
  types: 'types', interfaces: 'types', schemas: 'types', contracts: 'types', dtos: 'types',
  hooks: 'hooks',
  store: 'state', state: 'state', reducers: 'state', actions: 'state', slices: 'state',
  assets: 'assets', static: 'assets', public: 'assets',
  docs: 'documentation', documentation: 'documentation', wiki: 'documentation',
  deploy: 'infrastructure', deployment: 'infrastructure', infra: 'infrastructure',
  infrastructure: 'infrastructure', k8s: 'infrastructure', kubernetes: 'infrastructure',
  helm: 'infrastructure', charts: 'infrastructure', terraform: 'infrastructure',
  tf: 'infrastructure', docker: 'infrastructure',
  bin: 'entry', cmd: 'entry',
  '.github': 'ci-cd', '.gitlab': 'ci-cd', '.circleci': 'ci-cd'
};

// Also check file-level patterns
const filePatterns = [
  { regex: /\.(test|spec)\.[^.]+$/, label: 'test' },
  { regex: /^test_.*\.py$/, label: 'test' },
  { regex: /_test\.go$/, label: 'test' },
  { regex: /Test\.java$/, label: 'test' },
  { regex: /\.d\.ts$/, label: 'types' },
  { regex: /^(index\.(ts|js)|__init__\.py)$/, label: 'entry' },
  { regex: /^main\.(go|rs)$/, label: 'entry' },
  { regex: /^(Application\.java|Program\.cs)$/, label: 'entry' },
  { regex: /^(manage\.py|config\.ru)$/, label: 'entry' },
  { regex: /^(Cargo\.toml|go\.mod|Gemfile|pom\.xml|build\.gradle|composer\.json)$/, label: 'config' },
  { regex: /^(Dockerfile|docker-compose.*)$/, label: 'infrastructure' },
  { regex: /\.(tf|tfvars)$/, label: 'infrastructure' },
  { regex: /^(Jenkinsfile|\.gitlab-ci\.yml)$/, label: 'ci-cd' },
  { regex: /^Makefile$/, label: 'infrastructure' },
  { regex: /\.(sql)$/, label: 'data' },
  { regex: /\.(graphql|gql|proto)$/, label: 'types' },
  { regex: /\.(md|rst)$/, label: 'documentation' },
];

const patternMatches = {};
for (const group of Object.keys(directoryGroups)) {
  const lower = group.toLowerCase();
  if (dirPatterns[lower]) {
    patternMatches[group] = dirPatterns[lower];
  }
}

// Also compute file-level pattern for each file
const filePatternLabels = {};
for (const node of fileNodes) {
  const fp = getFilePath(node);
  const filename = path.basename(fp);
  for (const { regex, label } of filePatterns) {
    if (regex.test(filename) || regex.test(fp)) {
      filePatternLabels[node.id] = label;
      break;
    }
  }
}

// ─── H. Deployment Topology Detection ────────────────────────────────────────

const infraKeywords = ['Dockerfile', 'docker-compose', '.terraform', '.tf', 'k8s', 'kubernetes', 'helm', 'railway'];
const ciKeywords = ['.github/workflows', '.gitlab-ci', 'Jenkinsfile', '.circleci'];
const infraFiles = [];
let hasDockerfile = false, hasCompose = false, hasK8s = false, hasTerraform = false, hasCI = false;

for (const node of fileNodes) {
  const fp = getFilePath(node);
  if (/Dockerfile/.test(fp)) { hasDockerfile = true; infraFiles.push(fp); }
  if (/docker-compose/.test(fp)) { hasCompose = true; infraFiles.push(fp); }
  if (/k8s|kubernetes|helm/.test(fp)) { hasK8s = true; infraFiles.push(fp); }
  if (/\.tf(vars)?$/.test(fp) || /terraform/.test(fp)) { hasTerraform = true; infraFiles.push(fp); }
  if (ciKeywords.some(kw => fp.includes(kw))) { hasCI = true; infraFiles.push(fp); }
}

const deploymentTopology = {
  hasDockerfile, hasCompose, hasK8s, hasTerraform, hasCI,
  infraFiles: [...new Set(infraFiles)]
};

// ─── I. Data Pipeline Detection ───────────────────────────────────────────────

const schemaFiles = fileNodes.filter(n => {
  const fp = getFilePath(n);
  return /\.(graphql|gql|proto|prisma)$/.test(fp) || /schema\.sql/.test(fp);
}).map(n => getFilePath(n));

const migrationFiles = fileNodes.filter(n => {
  const fp = getFilePath(n);
  return /migrations?\//.test(fp) || /migration/.test(fp);
}).map(n => getFilePath(n));

const dataModelFiles = fileNodes.filter(n => {
  const fp = getFilePath(n);
  return /models?\//.test(fp) || /entities\//.test(fp) || n.tags?.includes('model');
}).map(n => getFilePath(n));

const apiHandlerFiles = fileNodes.filter(n => {
  const fp = getFilePath(n);
  return /routes?\/|controllers?\/|handlers?\/|endpoints?\//.test(fp) || n.tags?.includes('api-handler');
}).map(n => getFilePath(n));

const dataPipeline = { schemaFiles, migrationFiles, dataModelFiles, apiHandlerFiles };

// ─── J. Documentation Coverage ────────────────────────────────────────────────

const groupsWithDocs = new Set();
for (const node of fileNodes) {
  const fp = getFilePath(node);
  if (/\.(md|rst)$/i.test(fp) || node.type === 'document') {
    const group = getDirectoryGroup(fp);
    groupsWithDocs.add(group);
  }
}
const totalGroups = Object.keys(directoryGroups).length;
const undocumentedGroups = Object.keys(directoryGroups).filter(g => !groupsWithDocs.has(g));
const docCoverage = {
  groupsWithDocs: groupsWithDocs.size,
  totalGroups,
  coverageRatio: parseFloat((groupsWithDocs.size / totalGroups).toFixed(3)),
  undocumentedGroups
};

// ─── K. Dependency Direction ──────────────────────────────────────────────────

const pairImportCounts = {};
for (const { from, to, count } of interGroupImports) {
  const key = [from, to].sort().join('::');
  if (!pairImportCounts[key]) pairImportCounts[key] = { a: from, b: to, ab: 0, ba: 0 };
  if (pairImportCounts[key].a === from) pairImportCounts[key].ab += count;
  else pairImportCounts[key].ba += count;
}

const dependencyDirection = [];
for (const { a, b, ab, ba } of Object.values(pairImportCounts)) {
  if (ab > ba) dependencyDirection.push({ dependent: a, dependsOn: b });
  else if (ba > ab) dependencyDirection.push({ dependent: b, dependsOn: a });
}

// ─── File Stats ───────────────────────────────────────────────────────────────

const filesPerGroup = {};
for (const [group, ids] of Object.entries(directoryGroups)) {
  filesPerGroup[group] = ids.length;
}
const nodeTypeCounts = {};
for (const node of fileNodes) {
  nodeTypeCounts[node.type] = (nodeTypeCounts[node.type] || 0) + 1;
}
const fileStats = {
  totalFileNodes: fileNodes.length,
  filesPerGroup,
  nodeTypeCounts
};

// ─── Output ───────────────────────────────────────────────────────────────────

const result = {
  scriptCompleted: true,
  directoryGroups,
  nodeTypeGroups,
  crossCategoryEdges,
  interGroupImports,
  intraGroupDensity,
  patternMatches,
  filePatternLabels,
  deploymentTopology,
  dataPipeline,
  docCoverage,
  dependencyDirection,
  fileStats,
  fileFanIn: fanIn,
  fileFanOut: fanOut
};

fs.writeFileSync(outputPath, JSON.stringify(result, null, 2));
console.log('Done. Groups:', Object.keys(directoryGroups).join(', '));
console.log('Total nodes:', fileNodes.length);
