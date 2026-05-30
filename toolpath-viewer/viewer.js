import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";

const canvas = document.getElementById("viewport");
const fileInput = document.getElementById("fileInput");
const viewMode = document.getElementById("viewMode");
const layerMode = document.getElementById("layerMode");
const layerSlider = document.getElementById("layerSlider");
const layerLabel = document.getElementById("layerLabel");
const statusEl = document.getElementById("status");
const sourceTypeEl = document.getElementById("sourceType");
const layersCountEl = document.getElementById("layersCount");
const segmentsCountEl = document.getElementById("segmentsCount");
const boundsTextEl = document.getElementById("boundsText");
const processParamsEl = document.getElementById("processParams");

const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, powerPreference: "high-performance" });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 1.7));

const scene = new THREE.Scene();
scene.background = new THREE.Color(0x0b1015);

const camera3D = new THREE.PerspectiveCamera(45, 1, 0.1, 10000);
const camera2D = new THREE.OrthographicCamera(-100, 100, 100, -100, -1000, 10000);
let activeCamera = camera3D;

camera3D.up.set(0, 0, 1);
camera2D.up.set(0, 1, 0);

const controls = new OrbitControls(activeCamera, canvas);
controls.enableDamping = true;
controls.screenSpacePanning = true;

const axes = new THREE.AxesHelper(20);
const grid = new THREE.GridHelper(240, 24, 0x2c475f, 0x1c2e3d);
grid.rotation.x = Math.PI / 2;
scene.add(grid);
scene.add(axes);

const allLayersGroup = new THREE.Group();
const singleLayerGroup = new THREE.Group();
scene.add(allLayersGroup);
scene.add(singleLayerGroup);

let parsed = null;

function setStatus(text) {
  statusEl.textContent = text;
}

function clearGroup(group) {
  while (group.children.length > 0) {
    const obj = group.children.pop();
    obj.geometry?.dispose();
    obj.material?.dispose();
  }
}

function resize() {
  const w = canvas.clientWidth;
  const h = Math.max(1, canvas.clientHeight);
  renderer.setSize(w, h, false);
  camera3D.aspect = w / h;
  camera3D.updateProjectionMatrix();
}

window.addEventListener("resize", resize);
resize();

function emptyBounds() {
  return { minX: Infinity, minY: Infinity, minZ: Infinity, maxX: -Infinity, maxY: -Infinity, maxZ: -Infinity };
}

function updateBounds(bounds, x1, y1, z1, x2, y2, z2) {
  bounds.minX = Math.min(bounds.minX, x1, x2);
  bounds.minY = Math.min(bounds.minY, y1, y2);
  bounds.minZ = Math.min(bounds.minZ, z1, z2);
  bounds.maxX = Math.max(bounds.maxX, x1, x2);
  bounds.maxY = Math.max(bounds.maxY, y1, y2);
  bounds.maxZ = Math.max(bounds.maxZ, z1, z2);
}

function ensureLayer(layers, layerIndex) {
  if (!layers[layerIndex]) layers[layerIndex] = { segments: [], process: null };
  return layers[layerIndex];
}

function parseGcodeFast(text) {
  const lines = text.split(/\r?\n/);
  const layers = [];
  const bounds = emptyBounds();
  let x = 0, y = 0, z = 0, e = 0;
  let currentLayer = 0;
  let totalSegments = 0;

  const pushSeg = (layerIndex, x1, y1, z1, x2, y2, z2) => {
    ensureLayer(layers, layerIndex).segments.push(x1, y1, z1, x2, y2, z2);
    totalSegments += 1;
    updateBounds(bounds, x1, y1, z1, x2, y2, z2);
  };

  for (let i = 0; i < lines.length; i += 1) {
    const raw = lines[i];
    if (!raw) continue;
    if (raw.startsWith(";")) {
      if (raw.startsWith(";LAYER:")) {
        const idx = Number(raw.slice(7));
        if (Number.isFinite(idx)) currentLayer = idx;
      }
      continue;
    }

    const cut = raw.indexOf(";");
    const line = cut >= 0 ? raw.slice(0, cut).trim() : raw.trim();
    if (!(line.startsWith("G0") || line.startsWith("G1"))) continue;

    let nx = x, ny = y, nz = z, ne = e;
    const parts = line.split(/\s+/);
    for (let p = 1; p < parts.length; p += 1) {
      const token = parts[p];
      const key = token[0];
      const value = Number(token.slice(1));
      if (!Number.isFinite(value)) continue;
      if (key === "X") nx = value;
      else if (key === "Y") ny = value;
      else if (key === "Z") nz = value;
      else if (key === "E") ne = value;
    }

    const extruding = ne > e && (nx !== x || ny !== y || nz !== z);
    if (extruding) pushSeg(currentLayer, x, y, z, nx, ny, nz);
    x = nx; y = ny; z = nz; e = ne;
  }

  return { source: "gcode", layers, bounds, totalSegments };
}

function appendSegmentsFromPoints(points, target, boundsRef, counter, baseZ = 0, offX = 0, offY = 0) {
  if (!Array.isArray(points) || points.length < 2) return;
  for (let i = 1; i < points.length; i += 1) {
    const a = points[i - 1];
    const b = points[i];
    if (!Array.isArray(a) || !Array.isArray(b)) continue;
    const x1 = Number(a[0]) + offX;
    const y1 = Number(a[1]) + offY;
    const z1 = Number(a[2] ?? baseZ);
    const x2 = Number(b[0]) + offX;
    const y2 = Number(b[1]) + offY;
    const z2 = Number(b[2] ?? baseZ);
    if (![x1, y1, z1, x2, y2, z2].every(Number.isFinite)) continue;
    target.push(x1, y1, z1, x2, y2, z2);
    updateBounds(boundsRef, x1, y1, z1, x2, y2, z2);
    counter.value += 1;
  }
}

function collectJsonPaths(node, target, boundsRef, counter, baseZ = 0, offX = 0, offY = 0) {
  if (!node) return;
  if (node.type === "extrusion_path" && Array.isArray(node.points)) {
    appendSegmentsFromPoints(node.points, target, boundsRef, counter, baseZ, offX, offY);
    return;
  }
  if (Array.isArray(node.paths)) {
    for (const child of node.paths) collectJsonPaths(child, target, boundsRef, counter, baseZ, offX, offY);
    return;
  }
  if (Array.isArray(node)) {
    for (const child of node) collectJsonPaths(child, target, boundsRef, counter, baseZ, offX, offY);
  }
}

function parseJsonToolpaths(data) {
  const layers = [];
  const bounds = emptyBounds();
  const counter = { value: 0 };
  const objectOffsets = new Map();

  if (Array.isArray(data.objects)) {
    for (const obj of data.objects) {
      const c0 = obj?.copies?.[0];
      const ox = Number(c0?.[0] ?? 0);
      const oy = Number(c0?.[1] ?? 0);
      objectOffsets.set(Number(obj.object_index ?? 0), { ox, oy });
    }
  }

  if (Array.isArray(data.layers)) {
    for (let i = 0; i < data.layers.length; i += 1) {
      const srcLayer = data.layers[i] || {};
      const layer = ensureLayer(layers, i);
      layer.process = srcLayer.process ?? null;
      layer.meta = {
        layer_id: srcLayer.layer_id,
        print_z: srcLayer.print_z,
        is_support_layer: srcLayer.is_support_layer,
        is_raft_layer: srcLayer.is_raft_layer
      };

      const layerZ = Number(srcLayer.print_z ?? 0);
      const of = objectOffsets.get(Number(srcLayer.object_index ?? 0)) ?? { ox: 0, oy: 0 };

      if (Array.isArray(srcLayer.regions)) {
        for (const region of srcLayer.regions) {
          collectJsonPaths(region.perimeters, layer.segments, bounds, counter, layerZ, of.ox, of.oy);
          collectJsonPaths(region.infill_groups, layer.segments, bounds, counter, layerZ, of.ox, of.oy);
        }
      }

      collectJsonPaths(srcLayer.support?.interface_paths, layer.segments, bounds, counter, layerZ, of.ox, of.oy);
      collectJsonPaths(srcLayer.support?.support_paths, layer.segments, bounds, counter, layerZ, of.ox, of.oy);
    }
  }

  if (data.print_level_toolpaths) {
    const first = ensureLayer(layers, 0);
    const z0 = Number(data.layers?.[0]?.print_z ?? 0);
    collectJsonPaths(data.print_level_toolpaths.skirt, first.segments, bounds, counter, z0);
    collectJsonPaths(data.print_level_toolpaths.brim, first.segments, bounds, counter, z0);
  }

  return { source: "json", layers, bounds, totalSegments: counter.value, rawJson: data };
}

function buildAllLayersMeshes() {
  clearGroup(allLayersGroup);
  for (let i = 0; i < parsed.layers.length; i += 1) {
    const arr = parsed.layers[i]?.segments;
    if (!arr || arr.length === 0) continue;
    const geometry = new THREE.BufferGeometry();
    geometry.setAttribute("position", new THREE.Float32BufferAttribute(arr, 3));
    const hue = (i / Math.max(parsed.layers.length, 1)) * 0.55 + 0.1;
    const material = new THREE.LineBasicMaterial({ color: new THREE.Color().setHSL(hue, 0.88, 0.58), transparent: true, opacity: 0.9 });
    allLayersGroup.add(new THREE.LineSegments(geometry, material));
  }
}

function showSingleLayer(layerIdx) {
  clearGroup(singleLayerGroup);
  const arr = parsed.layers[layerIdx]?.segments;
  if (!arr || arr.length === 0) return;
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute("position", new THREE.Float32BufferAttribute(arr, 3));
  const material = new THREE.LineBasicMaterial({ color: 0xffd166 });
  singleLayerGroup.add(new THREE.LineSegments(geometry, material));
}

function fitCameraToBounds() {
  const b = parsed.bounds;
  const cx = (b.minX + b.maxX) * 0.5;
  const cy = (b.minY + b.maxY) * 0.5;
  const cz = (b.minZ + b.maxZ) * 0.5;
  const sx = Math.max(1, b.maxX - b.minX);
  const sy = Math.max(1, b.maxY - b.minY);
  const sz = Math.max(1, b.maxZ - b.minZ);
  const span = Math.max(sx, sy, sz);

  controls.target.set(cx, cy, cz);

  camera3D.position.set(cx + span * 1.1, cy - span * 0.9, cz + span * 0.9);
  camera3D.near = 0.1;
  camera3D.far = span * 40;
  camera3D.updateProjectionMatrix();

  camera2D.left = -sx * 0.55;
  camera2D.right = sx * 0.55;
  camera2D.top = sy * 0.55;
  camera2D.bottom = -sy * 0.55;
  camera2D.position.set(cx, cy, cz + span * 3);
  camera2D.lookAt(cx, cy, cz);
  camera2D.near = -span * 20;
  camera2D.far = span * 20;
  camera2D.updateProjectionMatrix();

  axes.scale.setScalar(Math.max(10, span * 0.08));
  grid.scale.setScalar(Math.max(1, span / 240));
  controls.update();
}

function updateProcessParams(layerIdx) {
  const layer = parsed.layers[layerIdx];
  if (!layer || !layer.process) {
    processParamsEl.textContent = "No per-layer process data available for this source.";
    return;
  }
  processParamsEl.textContent = JSON.stringify(layer.process, null, 2);
}

function updateVisibility() {
  const single = layerMode.value === "single";
  allLayersGroup.visible = !single;
  singleLayerGroup.visible = single;
  layerSlider.disabled = !single;
  if (single) {
    const idx = Number(layerSlider.value);
    showSingleLayer(idx);
    layerLabel.textContent = `${idx}`;
    updateProcessParams(idx);
  } else {
    layerLabel.textContent = "all";
    updateProcessParams(0);
  }
}

function switchViewMode() {
  activeCamera = viewMode.value === "2d" ? camera2D : camera3D;
  controls.object = activeCamera;
  controls.enableRotate = viewMode.value !== "2d";
  controls.update();
}

function updateStats() {
  const b = parsed.bounds;
  layersCountEl.textContent = `${parsed.layers.length}`;
  segmentsCountEl.textContent = `${parsed.totalSegments.toLocaleString()}`;
  boundsTextEl.textContent = `${(b.maxX - b.minX).toFixed(1)} x ${(b.maxY - b.minY).toFixed(1)} x ${(b.maxZ - b.minZ).toFixed(1)} mm`;
  sourceTypeEl.textContent = parsed.source.toUpperCase();
}

function onParsedData(data, sourceName) {
  parsed = data;
  buildAllLayersMeshes();
  layerSlider.min = "0";
  layerSlider.max = String(Math.max(0, parsed.layers.length - 1));
  layerSlider.value = "0";
  updateVisibility();
  updateStats();
  fitCameraToBounds();
  switchViewMode();
  setStatus(`Loaded ${sourceName}`);
}

fileInput.addEventListener("change", async (ev) => {
  const file = ev.target.files?.[0];
  if (!file) return;
  const text = await file.text();
  try {
    if (file.name.toLowerCase().endsWith(".json")) {
      onParsedData(parseJsonToolpaths(JSON.parse(text)), file.name);
    } else {
      onParsedData(parseGcodeFast(text), file.name);
    }
  } catch (err) {
    setStatus("Failed parsing file.");
    console.error(err);
  }
});

viewMode.addEventListener("change", switchViewMode);
layerMode.addEventListener("change", updateVisibility);
layerSlider.addEventListener("input", updateVisibility);

function animate() {
  requestAnimationFrame(animate);
  controls.update();
  renderer.render(scene, activeCamera);
}
animate();
