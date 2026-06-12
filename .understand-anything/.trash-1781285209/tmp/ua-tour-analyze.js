#!/usr/bin/env node
// Tour topology analysis script
const fs = require('fs');

const inputPath = process.argv[2];
const outputPath = process.argv[3];

if (!inputPath || !outputPath) {
  console.error('Usage: node ua-tour-analyze.js <input.json> <output.json>');
  process.exit(1);
}

let data;
try {
  data = JSON.parse(fs.readFileSync(inputPath, 'utf8'));
} catch (e) {
  console.error('Failed to parse input:', e.message);
  process.exit(1);
}

const nodes = data.nodes || [];
const edges = data.edges || [];
const layers = data.layers || [];

// A. Fan-In (how many nodes point TO this node)
const fanIn = {};
const fanOut = {};
nodes.forEach(n => { fanIn[n.id] = 0; fanOut[n.id] = 0; });

edges.forEach(e => {
  if (fanIn[e.target] !== undefined) fanIn[e.target]++;
  if (fanOut[e.source] !== undefined) fanOut[e.source]++;
});

const fanInRanking = Object.entries(fanIn)
  .sort((a, b) => b[1] - a[1])
  .slice(0, 20)
  .map(([id, count]) => {
    const n = nodes.find(x => x.id === id);
    return { id, fanIn: count, name: n ? n.name : id };
  });

const fanOutRanking = Object.entries(fanOut)
  .sort((a, b) => b[1] - a[1])
  .slice(0, 20)
  .map(([id, count]) => {
    const n = nodes.find(x => x.id === id);
    return { id, fanOut: count, name: n ? n.name : id };
  });

// B. Entry point candidates
const entryFilenames = new Set([
  'index.ts','index.js','main.ts','main.js','app.ts','app.js',
  'server.ts','server.js','mod.rs','main.go','main.py','main.rs',
  'manage.py','app.py','wsgi.py','asgi.py','run.py','__main__.py',
  'Application.java','Main.java','Program.cs','config.ru','index.php',
  'App.swift','Application.kt','main.cpp','main.c','cli.ts'
]);

const totalNodes = nodes.length;
const fanOutValues = Object.values(fanOut).sort((a, b) => a - b);
const fanInValues = Object.values(fanIn).sort((a, b) => a - b);
const top10FanOut = fanOutValues[Math.floor(totalNodes * 0.9)] || 0;
const bottom25FanIn = fanInValues[Math.floor(totalNodes * 0.25)] || 0;

const entryScores = nodes.map(n => {
  let score = 0;
  const parts = n.filePath ? n.filePath.split('/') : n.id.split('/');
  const depth = parts.length - 1;

  if (n.type === 'document') {
    if (n.name === 'README.md' && depth <= 1) score += 5;
    else if (n.name && n.name.endsWith('.md') && depth <= 1) score += 2;
  } else {
    if (entryFilenames.has(n.name)) score += 3;
    if (depth <= 1) score += 1;
    if (fanOut[n.id] >= top10FanOut) score += 1;
    if (fanIn[n.id] <= bottom25FanIn) score += 1;
  }
  return { id: n.id, score, name: n.name, summary: n.summary, type: n.type };
}).filter(x => x.score > 0).sort((a, b) => b.score - a.score).slice(0, 5);

// C. BFS from top code entry point
const topCodeEntry = entryScores.find(e => e.type === 'file') || entryScores[0];
let bfsResult = { startNode: null, order: [], depthMap: {}, byDepth: {} };

if (topCodeEntry) {
  const start = topCodeEntry.id;
  const visited = new Set();
  const queue = [{ id: start, depth: 0 }];
  visited.add(start);

  while (queue.length > 0) {
    const { id, depth } = queue.shift();
    bfsResult.order.push(id);
    bfsResult.depthMap[id] = depth;
    if (!bfsResult.byDepth[depth]) bfsResult.byDepth[depth] = [];
    bfsResult.byDepth[depth].push(id);

    const outEdges = edges.filter(e => e.source === id && ['imports','calls'].includes(e.type));
    for (const e of outEdges) {
      if (!visited.has(e.target)) {
        visited.add(e.target);
        queue.push({ id: e.target, depth: depth + 1 });
      }
    }
  }
  bfsResult.startNode = start;
}

// D. Non-code files
const nonCode = { documentation: [], infrastructure: [], data: [], config: [] };
nodes.forEach(n => {
  if (n.type === 'document') nonCode.documentation.push({ id: n.id, name: n.name, type: n.type, summary: n.summary });
  else if (['service','pipeline','resource'].includes(n.type)) nonCode.infrastructure.push({ id: n.id, name: n.name, type: n.type, summary: n.summary });
  else if (['table','schema','endpoint'].includes(n.type)) nonCode.data.push({ id: n.id, name: n.name, type: n.type, summary: n.summary });
  else if (n.type === 'config') nonCode.config.push({ id: n.id, name: n.name, type: n.type, summary: n.summary });
});

// E. Clusters (bidirectional edges)
const edgeSet = new Set(edges.map(e => `${e.source}|||${e.target}`));
const bidir = [];
const seen = new Set();
edges.forEach(e => {
  const rev = `${e.target}|||${e.source}`;
  const key = [e.source, e.target].sort().join('|||');
  if (edgeSet.has(rev) && !seen.has(key)) {
    seen.add(key);
    bidir.push([e.source, e.target]);
  }
});

// Expand clusters
const clusters = [];
bidir.forEach(pair => {
  let placed = false;
  for (const c of clusters) {
    if (c.nodes.includes(pair[0]) || c.nodes.includes(pair[1])) {
      pair.forEach(p => { if (!c.nodes.includes(p)) c.nodes.push(p); });
      c.edgeCount++;
      placed = true;
      break;
    }
  }
  if (!placed) clusters.push({ nodes: [...pair], edgeCount: 1 });
});
clusters.sort((a, b) => b.edgeCount - a.edgeCount);

// F. Node summary index
const nodeSummaryIndex = {};
nodes.forEach(n => {
  nodeSummaryIndex[n.id] = { name: n.name, type: n.type, summary: n.summary || '' };
});

const result = {
  scriptCompleted: true,
  entryPointCandidates: entryScores,
  fanInRanking,
  fanOutRanking,
  bfsTraversal: bfsResult,
  nonCodeFiles: nonCode,
  clusters: clusters.slice(0, 10),
  layers: { count: layers.length, list: layers },
  nodeSummaryIndex,
  totalNodes: nodes.length,
  totalEdges: edges.length
};

try {
  fs.writeFileSync(outputPath, JSON.stringify(result, null, 2));
  console.log(`Analysis complete: ${nodes.length} nodes, ${edges.length} edges`);
  process.exit(0);
} catch (e) {
  console.error('Failed to write output:', e.message);
  process.exit(1);
}
