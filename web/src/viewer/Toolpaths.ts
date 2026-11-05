import * as THREE from "three";

/** The print as OrcaSlicer will lay it down, one colour per feature, cut off at a chosen layer. */

export const FEATURES: { id: number; name: string; colour: string }[] = [
  { id: 0, name: "Outer wall", colour: "#f28c28" },
  { id: 1, name: "Inner wall", colour: "#f2c94c" },
  { id: 2, name: "Sparse infill", colour: "#eb5757" },
  { id: 3, name: "Solid infill", colour: "#9b51e0" },
  { id: 4, name: "Top surface", colour: "#e84393" },
  { id: 5, name: "Bottom surface", colour: "#5c6bc0" },
  { id: 6, name: "Support", colour: "#27ae60" },
  { id: 7, name: "Bridge", colour: "#2d9cdb" },
  { id: 8, name: "Other", colour: "#8a8a93" },
];

export type ToolpathData = { layers: number; z: Float32Array; offsets: Uint32Array; segments: Float32Array; features: Uint8Array };

/** Reads the format written by toolpaths.pack on the server. */
export function parseToolpaths(buffer: ArrayBuffer): ToolpathData {
  const [layers, count] = new Uint32Array(buffer, 0, 2);
  let at = 8;
  const z = new Float32Array(buffer, at, layers);
  at += layers * 4;
  const offsets = new Uint32Array(buffer, at, layers + 1);
  at += (layers + 1) * 4;
  const segments = new Float32Array(buffer, at, count * 4);
  at += count * 16;
  return { layers, z, offsets, segments, features: new Uint8Array(buffer, at, count) };
}

const VERTEX = `
  attribute vec4 segment;   // x0, y0, x1, y1
  attribute vec2 level;     // top of the layer, layer height
  uniform float width;
  varying vec3 vNormal;
  void main() {
    vec2 along = segment.zw - segment.xy;
    float len = length(along);
    vec2 dir = len > 0.0 ? along / len : vec2(1.0, 0.0);
    vec2 side = vec2(-dir.y, dir.x);
    // The box runs a little past both ends so that corners close up.
    vec2 xy = segment.xy + dir * (position.x * (len + width) - width * 0.5) + side * position.y * width;
    vec3 world = vec3(xy, level.x + position.z * level.y);
    vNormal = normalMatrix * vec3(dir * normal.x + side * normal.y, normal.z);
    gl_Position = projectionMatrix * modelViewMatrix * vec4(world, 1.0);
  }
`;

const FRAGMENT = `
  uniform vec3 colour;
  varying vec3 vNormal;
  void main() {
    vec3 n = normalize(vNormal);
    float light = 0.5 + 0.35 * max(dot(n, normalize(vec3(-0.3, 0.5, 0.8))), 0.0) + 0.2 * max(n.z, 0.0);
    gl_FragColor = vec4(colour * light, 1.0);
    #include <colorspace_fragment>
  }
`;

/** A box from x 0..1, y -0.5..0.5, z -1..0, stretched over each segment by the vertex shader. */
function unitBox(): THREE.BufferGeometry {
  const box = new THREE.BoxGeometry(1, 1, 1);
  box.translate(0.5, 0, -0.5);
  return box;
}

export class ToolpathView {
  group = new THREE.Group();
  private parts: { feature: number; mesh: THREE.Mesh; geometry: THREE.InstancedBufferGeometry; upTo: Uint32Array }[] = [];

  constructor(data: ToolpathData, lineWidth: number) {
    const box = unitBox();
    for (const f of FEATURES) {
      let count = 0;
      for (let i = 0; i < data.features.length; i++) if (data.features[i] === f.id) count++;
      if (!count) continue;
      const segment = new Float32Array(count * 4);
      const level = new Float32Array(count * 2);
      // How many of this feature's segments are in each layer or below it.
      const upTo = new Uint32Array(data.layers);
      let n = 0;
      for (let layer = 0; layer < data.layers; layer++) {
        const z = data.z[layer];
        const height = Math.max(z - (layer ? data.z[layer - 1] : 0), 0.04);
        for (let i = data.offsets[layer]; i < data.offsets[layer + 1]; i++) {
          if (data.features[i] !== f.id) continue;
          segment.set(data.segments.subarray(i * 4, i * 4 + 4), n * 4);
          level[n * 2] = z;
          level[n * 2 + 1] = height;
          n++;
        }
        upTo[layer] = n;
      }
      const geometry = new THREE.InstancedBufferGeometry();
      geometry.index = box.index;
      geometry.setAttribute("position", box.getAttribute("position"));
      geometry.setAttribute("normal", box.getAttribute("normal"));
      geometry.setAttribute("segment", new THREE.InstancedBufferAttribute(segment, 4));
      geometry.setAttribute("level", new THREE.InstancedBufferAttribute(level, 2));
      geometry.instanceCount = n;
      const material = new THREE.ShaderMaterial({
        vertexShader: VERTEX,
        fragmentShader: FRAGMENT,
        uniforms: { colour: { value: new THREE.Color(f.colour) }, width: { value: lineWidth } },
      });
      const mesh = new THREE.Mesh(geometry, material);
      mesh.frustumCulled = false;
      this.group.add(mesh);
      this.parts.push({ feature: f.id, mesh, geometry, upTo });
    }
  }

  /** Features this print has. */
  get features(): number[] {
    return this.parts.map((p) => p.feature);
  }

  /** Show layers up to and including this one, hiding everything above. */
  setLayer(layer: number): void {
    for (const p of this.parts) p.geometry.instanceCount = p.upTo[layer] ?? 0;
  }

  setFeatureVisible(feature: number, on: boolean): void {
    for (const p of this.parts) if (p.feature === feature) p.mesh.visible = on;
  }

  dispose(): void {
    for (const p of this.parts) {
      p.geometry.dispose();
      (p.mesh.material as THREE.Material).dispose();
    }
  }
}
