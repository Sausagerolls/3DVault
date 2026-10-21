import * as THREE from "three";
import { GLTFLoader } from "three/examples/jsm/loaders/GLTFLoader.js";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";

const loader = new GLTFLoader();
const geometryCache = new Map<string, Promise<THREE.BufferGeometry>>();

/** Load a GLB preview and return one merged geometry. Cached per URL. */
export function loadGeometry(url: string): Promise<THREE.BufferGeometry> {
  let p = geometryCache.get(url);
  if (!p) {
    p = loader.loadAsync(url).then((gltf) => {
      const geoms: THREE.BufferGeometry[] = [];
      gltf.scene.updateMatrixWorld(true);
      gltf.scene.traverse((o) => {
        const mesh = o as THREE.Mesh;
        if (mesh.isMesh) {
          const g = mesh.geometry.clone().applyMatrix4(mesh.matrixWorld);
          geoms.push(g.index ? g.toNonIndexed() : g);
        }
      });
      if (!geoms.length) throw new Error("Empty preview");
      const merged = geoms.length === 1 ? geoms[0] : mergeNonIndexed(geoms);
      merged.deleteAttribute("normal");
      merged.computeVertexNormals();
      merged.computeBoundingBox();
      merged.computeBoundingSphere();
      return merged;
    });
    p.catch(() => geometryCache.delete(url));
    geometryCache.set(url, p);
    if (geometryCache.size > 40) geometryCache.delete(geometryCache.keys().next().value!);
  }
  return p;
}

function mergeNonIndexed(geoms: THREE.BufferGeometry[]): THREE.BufferGeometry {
  const total = geoms.reduce((n, g) => n + g.getAttribute("position").count, 0);
  const pos = new Float32Array(total * 3);
  let offset = 0;
  for (const g of geoms) {
    const a = g.getAttribute("position").array as Float32Array;
    pos.set(a, offset);
    offset += a.length;
  }
  const out = new THREE.BufferGeometry();
  out.setAttribute("position", new THREE.BufferAttribute(pos, 3));
  return out;
}

export type ViewerOptions = { interactive?: boolean; autoRotate?: boolean; showBed?: boolean; color?: string };

export class Viewer {
  renderer: THREE.WebGLRenderer;
  scene = new THREE.Scene();
  camera = new THREE.PerspectiveCamera(35, 1, 0.1, 10000);
  controls?: OrbitControls;
  root = new THREE.Group();
  material: THREE.MeshStandardMaterial;
  mesh?: THREE.Mesh;
  bed?: THREE.Object3D;
  private frame = 0;
  private running = false;
  private resizeObs: ResizeObserver;
  private loadToken = 0;

  constructor(public container: HTMLElement, private opts: ViewerOptions = {}) {
    this.renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, preserveDrawingBuffer: false });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    this.renderer.outputColorSpace = THREE.SRGBColorSpace;
    container.appendChild(this.renderer.domElement);
    this.renderer.domElement.style.display = "block";

    // Printing files are Z-up; three.js is Y-up.
    this.root.rotation.x = -Math.PI / 2;
    this.scene.add(this.root);
    this.scene.add(new THREE.HemisphereLight(0xffffff, 0x404050, 1.6));
    const key = new THREE.DirectionalLight(0xffffff, 2.2);
    key.position.set(-1, 2, 1.5);
    this.camera.add(key);
    const fill = new THREE.DirectionalLight(0xffffff, 0.6);
    fill.position.set(1.5, -0.5, 1);
    this.camera.add(fill);
    this.scene.add(this.camera);

    this.material = new THREE.MeshStandardMaterial({
      color: opts.color ?? "#f08c3a",
      roughness: 0.55,
      metalness: 0.05,
      flatShading: false,
      side: THREE.DoubleSide,
    });

    if (opts.interactive) {
      this.controls = new OrbitControls(this.camera, this.renderer.domElement);
      this.controls.enableDamping = true;
      this.controls.addEventListener("change", () => this.requestRender());
      this.controls.addEventListener("start", () => this.setAutoRotate(false));
    }
    this.resizeObs = new ResizeObserver(() => this.resize());
    this.resizeObs.observe(container);
    this.resize();
  }

  async load(url: string): Promise<void> {
    const token = ++this.loadToken;
    const geom = await loadGeometry(url);
    if (token !== this.loadToken) return;
    if (this.mesh) this.root.remove(this.mesh);
    this.mesh = new THREE.Mesh(geom, this.material);
    this.root.add(this.mesh);
    if (this.opts.showBed) this.buildBed(geom.boundingBox!);
    this.frameModel();
    if (this.opts.autoRotate) this.setAutoRotate(true);
    this.requestRender();
  }

  clear(): void {
    this.loadToken++;
    if (this.mesh) this.root.remove(this.mesh);
    this.mesh = undefined;
    this.requestRender();
  }

  private buildBed(box: THREE.Box3): void {
    if (this.bed) this.root.remove(this.bed);
    const size = box.getSize(new THREE.Vector3());
    const extent = Math.max(size.x, size.y) * 1.6 || 100;
    const step = extent > 400 ? 50 : extent > 120 ? 10 : 5;
    const n = Math.ceil(extent / step / 2) * 2;
    const grid = new THREE.GridHelper(n * step, n, 0x666670, 0x3a3a42);
    grid.rotation.x = Math.PI / 2; // into the Z-up root
    (grid.material as THREE.Material).transparent = true;
    (grid.material as THREE.Material).opacity = 0.6;
    this.bed = grid;
    this.root.add(grid);
  }

  frameModel(): void {
    if (!this.mesh) return;
    this.root.updateMatrixWorld(true);
    const sphere = this.mesh.geometry.boundingSphere!.clone().applyMatrix4(this.root.matrixWorld);
    const fov = (this.camera.fov * Math.PI) / 180;
    const dist = sphere.radius / Math.sin(fov / 2) * 1.05;
    const dir = new THREE.Vector3(0.75, 0.55, 1).normalize();
    this.camera.position.copy(sphere.center).addScaledVector(dir, dist);
    this.camera.near = dist / 100;
    this.camera.far = dist * 100;
    this.camera.updateProjectionMatrix();
    this.camera.lookAt(sphere.center);
    if (this.controls) {
      this.controls.target.copy(sphere.center);
      this.controls.update();
    }
  }

  setWireframe(on: boolean): void {
    this.material.wireframe = on;
    this.requestRender();
  }

  setAutoRotate(on: boolean): void {
    this.running = on;
    if (on) this.loop();
  }

  private loop = () => {
    if (!this.running) return;
    const target = this.controls?.target ?? this.mesh?.geometry.boundingSphere?.center ?? new THREE.Vector3();
    const offset = this.camera.position.clone().sub(target);
    offset.applyAxisAngle(new THREE.Vector3(0, 1, 0), 0.012);
    this.camera.position.copy(target).add(offset);
    this.camera.lookAt(target);
    this.renderNow();
    this.frame = requestAnimationFrame(this.loop);
  };

  requestRender(): void {
    if (this.running) return;
    cancelAnimationFrame(this.frame);
    this.frame = requestAnimationFrame(() => {
      this.controls?.update();
      this.renderNow();
    });
  }

  private renderNow(): void {
    this.renderer.render(this.scene, this.camera);
  }

  resize(): void {
    const w = this.container.clientWidth || 1;
    const h = this.container.clientHeight || 1;
    this.renderer.setSize(w, h, false);
    this.renderer.domElement.style.width = "100%";
    this.renderer.domElement.style.height = "100%";
    this.camera.aspect = w / h;
    this.camera.updateProjectionMatrix();
    this.requestRender();
  }

  dispose(): void {
    this.running = false;
    cancelAnimationFrame(this.frame);
    this.resizeObs.disconnect();
    this.controls?.dispose();
    this.material.dispose();
    this.renderer.dispose();
    this.renderer.domElement.remove();
  }
}
