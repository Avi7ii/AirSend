#!/usr/bin/env node

import { readFile, writeFile } from "node:fs/promises";

const [inputPath, outputPath] = process.argv.slice(2);

if (!inputPath || !outputPath) {
  console.error("Usage: update-star-history.mjs <stargazers.json> <output.svg>");
  process.exit(1);
}

const raw = JSON.parse(await readFile(inputPath, "utf8"));
const pages = Array.isArray(raw) && Array.isArray(raw[0]) ? raw.flat() : raw;
const timestamps = pages
  .map((entry) => Date.parse(entry.starred_at))
  .filter(Number.isFinite)
  .sort((a, b) => a - b);

const width = 1200;
const height = 560;
const plot = { left: 96, right: 48, top: 92, bottom: 92 };
const plotWidth = width - plot.left - plot.right;
const plotHeight = height - plot.top - plot.bottom;
const maxStars = Math.max(timestamps.length, 1);
const firstTime = timestamps[0] ?? Date.now();
const lastTime = timestamps.at(-1) ?? firstTime + 86400000;
const timeSpan = Math.max(lastTime - firstTime, 86400000);

const x = (time) => plot.left + ((time - firstTime) / timeSpan) * plotWidth;
const y = (stars) => plot.top + plotHeight - (stars / maxStars) * plotHeight;
const points = timestamps.map((time, index) => `${x(time).toFixed(2)},${y(index + 1).toFixed(2)}`);
const path = points.length > 1 ? `M ${points.join(" L ")}` : `M ${plot.left},${y(0)} L ${plot.left + plotWidth},${y(maxStars)}`;
const dateLabel = (time) => new Date(time).toISOString().slice(0, 10);
const tickCount = 5;
const yTicks = Array.from({ length: tickCount + 1 }, (_, index) => Math.round((maxStars * index) / tickCount));
const xTicks = Array.from({ length: 6 }, (_, index) => firstTime + (timeSpan * index) / 5);

const grid = yTicks.map((value) => {
  const yy = y(value);
  return `<line x1="${plot.left}" y1="${yy.toFixed(2)}" x2="${width - plot.right}" y2="${yy.toFixed(2)}" class="grid"/><text x="${plot.left - 18}" y="${(yy + 5).toFixed(2)}" class="axis y-label" text-anchor="end">${value}</text>`;
}).join("");

const dates = xTicks.map((time) => {
  const xx = x(time);
  return `<line x1="${xx.toFixed(2)}" y1="${plot.top}" x2="${xx.toFixed(2)}" y2="${height - plot.bottom}" class="grid vertical"/><text x="${xx.toFixed(2)}" y="${height - plot.bottom + 34}" class="axis" text-anchor="middle">${dateLabel(time)}</text>`;
}).join("");

const markers = timestamps.map((time, index) => {
  const radius = timestamps.length > 120 ? 1.6 : 3;
  return `<circle cx="${x(time).toFixed(2)}" cy="${y(index + 1).toFixed(2)}" r="${radius}" class="marker"/>`;
}).join("");

const svg = `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} ${height}" role="img" aria-labelledby="title description">
  <title id="title">AirSend Star History</title>
  <desc id="description">GitHub stars for Avi7ii/AirSend over time.</desc>
  <style>
    .background { fill: #0f172a; }
    .title { fill: #f8fafc; font: 700 30px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    .subtitle { fill: #94a3b8; font: 500 15px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    .axis { fill: #94a3b8; font: 500 13px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    .y-label { fill: #cbd5e1; }
    .grid { stroke: #334155; stroke-width: 1; opacity: .72; }
    .vertical { opacity: .34; }
    .line { fill: none; stroke: #60a5fa; stroke-width: 4; stroke-linecap: round; stroke-linejoin: round; }
    .marker { fill: #bfdbfe; stroke: #60a5fa; stroke-width: 1.5; }
    .badge { fill: #1e293b; stroke: #475569; stroke-width: 1; }
    .badge-label { fill: #e2e8f0; font: 700 16px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  </style>
  <rect width="${width}" height="${height}" rx="20" class="background"/>
  <text x="${plot.left}" y="42" class="title">AirSend Star History</text>
  <text x="${plot.left}" y="68" class="subtitle">Avi7ii/AirSend · ${timestamps.length} GitHub stars</text>
  ${grid}
  ${dates}
  <path d="${path}" class="line"/>
  ${markers}
  <rect x="${width - 244}" y="28" width="196" height="40" rx="20" class="badge"/>
  <text x="${width - 146}" y="54" class="badge-label" text-anchor="middle">${timestamps.length} stars</text>
</svg>
`;

await writeFile(outputPath, svg);
