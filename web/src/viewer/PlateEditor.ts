import * as THREE from "three";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";
import { TransformControls } from "three/examples/jsm/controls/TransformControls.js";
import { STLLoader } from "three/examples/jsm/loaders/STLLoader.js";
import { CONTAINED, INTERSECTED, MeshBVH, NOT_INTERSECTED, acceleratedRaycast } from "three-mesh-bvh";
import { ToolpathView, type ToolpathData } from "./Toolpaths";

export type Tool = "select" | "move" | "rotate" | "flat" | "enforce" | "block" | "erase";
export type Volume = { x: number; y: number; z: number };

/** What each triangle is painted with. The values are this editor's own, not OrcaSlicer's. */
const NOT_PAINTED = 0;
const ENFORCE = 1;
const BLOCK = 2;

const BASE = new THREE.Color("#7f8ca3");
const ENFORCE_COLOUR = new THREE.Color("#23c26b");
const BLOCK_COLOUR = new THREE.Color("#e5484d");
const OVERHANG_COLOUR = new THREE.Color("#f2b84b");
const OUT_OF_BOUNDS = new THREE.Color("#ff8080");
const GAP_MM = 6;

export type PlateItem = { file_id: number; object: number; name: string; matrix: number[]; enforce: number[]; block: number[] };
type Loaded = { geometry: THREE.BufferGeometry; centre: THREE.Vector3; faces: number };

export class PlateObject {
  constructor(
    public id: number,
    public fileId: number,
    public object: number,
    public plate: number,
    public name: string,
    public mesh: THREE.Mesh<THREE.BufferGeometry, THREE.MeshStandardMaterial>,
    /** The geometry is moved to its own centre to turn around it. This is how far. */
    public centre: THREE.Vector3,
    public paint: Uint8Array,
  ) {}
  outOfBounds = false;

  /** Position and rotation on the plate, relative to the original file's coordinates. */
  matrix(): number[] {
    this.mesh.updateMatrixWorld(true);
    const m = this.mesh.matrixWorld.clone().multiply(new THREE.Matrix4().makeTranslation(-this.centre.x, -this.centre.y, -this.centre.z));
    return Array.from(m.elements);
  }

  /** Painted triangles of one kind as [start, count, start, count, ...]. */
  runs(kind: number): number[] {
    const out: number[] = [];
    let start = -1;
    for (let i = 0; i <= this.paint.length; i++) {
      const on = i < this.paint.length && this.paint[i] === kind;
      if (on && start < 0) start = i;
      if (!on && start >= 0) {
        out.push(start, i - start);
        start = -1;
      }
    }
    return out;
  }

  get painted(): boolean {
    return this.paint.some((p) => p !== NOT_PAINTED);
  }
}

export type Transform = { x: number; y: number; rx: number; ry: number; rz: number; scale: number };

/**
 * The 3D plate: place parts, lay them flat and paint where supports go. Z is up, and one unit is
 * one millimetre with the origin at the plate's front left corner, the same as the printer.
 */
export class PlateEditor {
  /** Parts on every plate. Only those on the current plate are shown, edited and sliced. */
  allObjects: PlateObject[] = [];
  plate = 1;
  selected: PlateObject | null = null;
  tool: Tool = "select";
  brushMm = 4;
  showOverhangs = false;
  overhangAngle = 30;
  /** Called after anything changes that the panels show. */
  onChange: () => void = () => {};
  /** Right click or long press on a part, at these page coordinates. */
  onPartMenu: (o: PlateObject, x: number, y: number) => void = () => {};
  /** Called the first time a triangle is painted in a stroke. */
  onPaint: (kind: "enforce" | "block" | "erase") => void = () => {};

  private renderer: THREE.WebGLRenderer;
  private scene = new THREE.Scene();
  private camera = new THREE.PerspectiveCamera(35, 1, 1, 10000);
  private controls: OrbitControls;
  private transform: TransformControls;
  private bed = new THREE.Group();
  private brush: THREE.Mesh;
  private raycaster = new THREE.Raycaster();
  private volume: Volume = { x: 180, y: 180, z: 180 };
  private nextId = 1;
  private frame = 0;
  private resizeObserver: ResizeObserver;
  private pointers = new Map<number, { x: number; y: number }>();
  private painting = false;
  private downAt: { x: number; y: number } | null = null;
  private renderScheduled = false;
  private viewMoved = false;
  private toolpaths: ToolpathView | null = null;
  private geometries = new Map<string, Promise<Loaded>>();
  private longPress = 0;

  constructor(private container: HTMLElement) {
    this.renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    container.appendChild(this.renderer.domElement);
    const canvas = this.renderer.domElement;
    canvas.style.display = "block";
    canvas.style.touchAction = "none";

    this.camera.up.set(0, 0, 1);
    this.scene.add(new THREE.HemisphereLight(0xffffff, 0x50505a, 1.7));
    const key = new THREE.DirectionalLight(0xffffff, 1.9);
    key.position.set(-1, 1.5, 2);
    this.camera.add(key);
    this.scene.add(this.camera, this.bed);

    this.controls = new OrbitControls(this.camera, canvas);
    this.controls.enableDamping = false;
    this.controls.addEventListener("change", () => this.render());
    this.controls.addEventListener("start", () => { this.viewMoved = true; });

    this.transform = new TransformControls(this.camera, canvas);
    this.transform.showZ = false;
    this.transform.setSize(0.8);
    this.transform.addEventListener("dragging-changed", (e) => {
      this.controls.enabled = !e.value;
      if (!e.value && this.selected) {
        this.settle(this.selected);
        this.onChange();
      }
    });
    this.transform.addEventListener("change", () => this.render());
    this.transform.addEventListener("objectChange", () => this.onChange());
    this.scene.add(this.transform.getHelper());

    this.brush = new THREE.Mesh(
      new THREE.SphereGeometry(1, 24, 16),
      new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.22, depthWrite: false }),
    );
    this.brush.visible = false;
    this.scene.add(this.brush);

    canvas.addEventListener("pointerdown", this.pointerDown);
    canvas.addEventListener("pointermove", this.pointerMove);
    canvas.addEventListener("pointerleave", this.pointerLeave);
    window.addEventListener("pointerup", this.pointerUp);
    window.addEventListener("pointercancel", this.pointerUp);

    this.setVolume(this.volume);
    this.resizeObserver = new ResizeObserver(() => this.resize());
    this.resizeObserver.observe(container);
    this.resize();
    this.setTool("select");
  }

  dispose(): void {
    cancelAnimationFrame(this.frame);
    this.resizeObserver.disconnect();
    const canvas = this.renderer.domElement;
    canvas.removeEventListener("pointerdown", this.pointerDown);
    canvas.removeEventListener("pointermove", this.pointerMove);
    canvas.removeEventListener("pointerleave", this.pointerLeave);
    window.removeEventListener("pointerup", this.pointerUp);
    window.removeEventListener("pointercancel", this.pointerUp);
    this.transform.dispose();
    this.controls.dispose();
    clearTimeout(this.longPress);
    for (const o of this.allObjects) {
      o.mesh.geometry.dispose();
      o.mesh.material.dispose();
    }
    this.renderer.dispose();
    canvas.remove();
  }

  // ---------------------------------------------------------------- sliced preview

  /** Swap the parts for the sliced print, including its supports. */
  showToolpaths(data: ToolpathData, lineWidth: number): number[] {
    this.hideToolpaths();
    this.toolpaths = new ToolpathView(data, lineWidth);
    this.scene.add(this.toolpaths.group);
    for (const o of this.allObjects) o.mesh.visible = false;
    this.transform.detach();
    this.setTool("select");
    this.render();
    return this.toolpaths.features;
  }

  hideToolpaths(): void {
    if (this.toolpaths) {
      this.scene.remove(this.toolpaths.group);
      this.toolpaths.dispose();
      this.toolpaths = null;
    }
    for (const o of this.allObjects) o.mesh.visible = o.plate === this.plate;
    this.syncGizmo();
    this.render();
  }

  setToolpathLayer(layer: number): void {
    this.toolpaths?.setLayer(layer);
    this.render();
  }

  setToolpathFeature(feature: number, on: boolean): void {
    this.toolpaths?.setFeatureVisible(feature, on);
    this.render();
  }

  // ---------------------------------------------------------------- plate

  setVolume(volume: Volume): void {
    this.volume = volume;
    this.bed.clear();
    const { x, y, z } = volume;
    const top = new THREE.Mesh(new THREE.PlaneGeometry(x, y), new THREE.MeshBasicMaterial({ color: 0x3a3a44, transparent: true, opacity: 0.55 }));
    top.position.set(x / 2, y / 2, -0.05);
    this.bed.add(top);
    const lines: number[] = [];
    const step = x >= 300 ? 50 : 20;
    for (let i = 0; i <= x + 0.01; i += step) lines.push(i, 0, 0, i, y, 0);
    for (let j = 0; j <= y + 0.01; j += step) lines.push(0, j, 0, x, j, 0);
    const grid = new THREE.BufferGeometry();
    grid.setAttribute("position", new THREE.Float32BufferAttribute(lines, 3));
    this.bed.add(new THREE.LineSegments(grid, new THREE.LineBasicMaterial({ color: 0x70707e, transparent: true, opacity: 0.6 })));
    const box = new THREE.LineSegments(
      new THREE.EdgesGeometry(new THREE.BoxGeometry(x, y, z)),
      new THREE.LineBasicMaterial({ color: 0x70707e, transparent: true, opacity: 0.35 }),
    );
    box.position.set(x / 2, y / 2, z / 2);
    this.bed.add(box);
    this.home();
    for (const o of this.objects) this.settle(o);
  }

  /** Back to the view from the front. */
  home(): void {
    const { x, y, z } = this.volume;
    this.controls.target.set(x / 2, y / 2, Math.min(z, x) * 0.15);
    // A tall, narrow view has to stand further back to fit the plate's width.
    const d = (Math.max(x, y, z) * 2.3) / Math.min(1, this.camera.aspect / 1.2);
    this.camera.position.set(x / 2, y / 2 - d * 0.82, d * 0.62);
    this.camera.far = d * 8;
    this.camera.updateProjectionMatrix();
    this.controls.update();
    this.render();
  }

  // ---------------------------------------------------------------- parts

  /** Parts on the current plate. */
  get objects(): PlateObject[] {
    return this.allObjects.filter((o) => o.plate === this.plate);
  }

  private load(fileId: number, object: number): Promise<Loaded> {
    const key = `${fileId}:${object}`;
    let loading = this.geometries.get(key);
    if (!loading) {
      loading = new STLLoader().loadAsync(`/api/v1/files/${fileId}/editor-mesh?object=${object}`).then((geometry) => {
        geometry.computeBoundingBox();
        const centre = geometry.boundingBox!.getCenter(new THREE.Vector3());
        geometry.translate(-centre.x, -centre.y, -centre.z);
        geometry.computeBoundingSphere();
        // "indirect" keeps the triangles in the file's order, which painting is sent back in.
        geometry.boundsTree = new MeshBVH(geometry, { indirect: true });
        return { geometry, centre, faces: geometry.getAttribute("position").count / 3 };
      });
      loading.catch(() => this.geometries.delete(key));
      this.geometries.set(key, loading);
    }
    return loading;
  }

  /**
   * Add a copy of an object to a plate. With a matrix it goes where its project had it, which
   * place() can then shift as a group. Without one it finds a free spot on the plate.
   */
  async add(fileId: number, object: number, name: string, plate: number, matrix?: number[] | null): Promise<PlateObject> {
    const { geometry, centre, faces } = await this.load(fileId, object);
    const o = this.place(fileId, object, plate, name, this.shareShape(geometry), centre, new Uint8Array(faces));
    if (matrix) {
      new THREE.Matrix4().fromArray(matrix).multiply(new THREE.Matrix4().makeTranslation(centre.x, centre.y, centre.z))
        .decompose(o.mesh.position, o.mesh.quaternion, o.mesh.scale);
      o.mesh.updateMatrixWorld(true);
    } else {
      this.moveToFreeSpot(o);
    }
    this.onChange();
    return o;
  }

  /** The shape is shared between copies, while the paint and colours belong to each. */
  private shareShape(from: THREE.BufferGeometry): THREE.BufferGeometry {
    const g = new THREE.BufferGeometry();
    g.setAttribute("position", from.getAttribute("position"));
    g.setAttribute("normal", from.getAttribute("normal"));
    g.boundsTree = from.boundsTree;
    g.boundingSphere = from.boundingSphere;
    g.boundingBox = from.boundingBox;
    return g;
  }

  /** Centre a project's parts on the plate as a group, keeping how they sit relative to each other. */
  centreGroup(group: PlateObject[]): void {
    const box = new THREE.Box3();
    for (const o of group) box.expandByObject(o.mesh, true);
    if (box.isEmpty()) return;
    const dx = this.volume.x / 2 - (box.min.x + box.max.x) / 2;
    const dy = this.volume.y / 2 - (box.min.y + box.max.y) / 2;
    for (const o of group) {
      o.mesh.position.x += dx;
      o.mesh.position.y += dy;
      this.settle(o);
    }
    this.onChange();
  }

  /** Show another plate. Its parts stay on it, and only the shown plate is edited or sliced. */
  setPlate(plate: number): void {
    this.plate = plate;
    this.select(null);
    for (const o of this.allObjects) {
      o.mesh.visible = o.plate === plate && !this.toolpaths;
      if (o.plate === plate) this.settle(o);
    }
    this.onChange();
    this.render();
  }

  moveToPlate(o: PlateObject, plate: number): void {
    if (this.selected === o) this.select(null);
    o.plate = plate;
    o.mesh.visible = plate === this.plate;
    this.moveToFreeSpot(o);
    this.onChange();
    this.render();
  }

  private place(fileId: number, object: number, plate: number, name: string, geometry: THREE.BufferGeometry, centre: THREE.Vector3, paint: Uint8Array): PlateObject {
    geometry.setAttribute("color", new THREE.BufferAttribute(new Float32Array(geometry.getAttribute("position").count * 3), 3));
    const material = new THREE.MeshStandardMaterial({ vertexColors: true, roughness: 0.6, metalness: 0.02, side: THREE.DoubleSide });
    const mesh = new THREE.Mesh(geometry, material);
    mesh.raycast = acceleratedRaycast;
    const o = new PlateObject(this.nextId++, fileId, object, plate, name, mesh, centre, paint);
    mesh.visible = plate === this.plate && !this.toolpaths;
    this.allObjects.push(o);
    this.scene.add(mesh);
    this.colourAll(o);
    return o;
  }

  duplicate(o: PlateObject): void {
    const copy = this.place(o.fileId, o.object, o.plate, o.name, this.shareShape(o.mesh.geometry), o.centre, o.paint.slice());
    copy.mesh.position.copy(o.mesh.position);
    copy.mesh.quaternion.copy(o.mesh.quaternion);
    copy.mesh.scale.copy(o.mesh.scale);
    this.moveToFreeSpot(copy);
    this.select(copy);
  }

  remove(o: PlateObject): void {
    if (this.selected === o) this.select(null);
    this.scene.remove(o.mesh);
    o.mesh.material.dispose();
    this.allObjects = this.allObjects.filter((x) => x !== o);
    this.refreshBounds();
    this.onChange();
    this.render();
  }

  select(o: PlateObject | null): void {
    if (this.selected) this.selected.mesh.material.emissive.setHex(0x000000);
    this.selected = o;
    if (o) o.mesh.material.emissive.setHex(0x2a1a08);
    this.syncGizmo();
    this.onChange();
    this.render();
  }

  setTool(tool: Tool): void {
    this.tool = tool;
    const painting = tool === "enforce" || tool === "block" || tool === "erase";
    // While painting, one finger or the left button paints, so turning the view moves to two
    // fingers or the right button.
    this.controls.mouseButtons = {
      LEFT: painting ? (null as unknown as THREE.MOUSE) : THREE.MOUSE.ROTATE,
      MIDDLE: THREE.MOUSE.DOLLY,
      RIGHT: painting ? THREE.MOUSE.ROTATE : THREE.MOUSE.PAN,
    };
    this.controls.touches = {
      ONE: painting ? (null as unknown as THREE.TOUCH) : THREE.TOUCH.ROTATE,
      TWO: painting ? THREE.TOUCH.DOLLY_ROTATE : THREE.TOUCH.DOLLY_PAN,
    };
    this.brush.visible = false;
    this.syncGizmo();
    this.onChange();
    this.render();
  }

  private syncGizmo(): void {
    if (!this.toolpaths && this.selected && (this.tool === "move" || this.tool === "rotate")) {
      this.transform.setMode(this.tool === "move" ? "translate" : "rotate");
      this.transform.showX = this.transform.showY = true;
      this.transform.showZ = this.tool === "rotate";
      this.transform.attach(this.selected.mesh);
    } else {
      this.transform.detach();
    }
  }

  getTransform(o: PlateObject): Transform {
    const deg = THREE.MathUtils.radToDeg;
    return {
      x: o.mesh.position.x, y: o.mesh.position.y,
      rx: deg(o.mesh.rotation.x), ry: deg(o.mesh.rotation.y), rz: deg(o.mesh.rotation.z),
      scale: o.mesh.scale.x * 100,
    };
  }

  setTransform(o: PlateObject, t: Partial<Transform>): void {
    const rad = THREE.MathUtils.degToRad;
    const c = this.getTransform(o);
    const n = { ...c, ...t };
    o.mesh.position.x = n.x;
    o.mesh.position.y = n.y;
    o.mesh.rotation.set(rad(n.rx), rad(n.ry), rad(n.rz));
    o.mesh.scale.setScalar(Math.max(n.scale, 1) / 100);
    this.settle(o);
    this.onChange();
  }

  /** Put a new part in the empty place nearest the plate's centre, leaving the others alone. */
  private moveToFreeSpot(o: PlateObject): void {
    const { x: width, y: depth } = this.volume;
    o.mesh.position.set(width / 2, depth / 2, 0);
    o.mesh.updateMatrixWorld(true);
    const size = new THREE.Box3().setFromObject(o.mesh, true).getSize(new THREE.Vector3());
    const others = this.allObjects.filter((x) => x !== o && x.plate === o.plate).map((x) => new THREE.Box3().setFromObject(x.mesh, true));
    const free = (px: number, py: number) =>
      others.every((b) =>
        px + size.x / 2 + GAP_MM <= b.min.x || px - size.x / 2 - GAP_MM >= b.max.x ||
        py + size.y / 2 + GAP_MM <= b.min.y || py - size.y / 2 - GAP_MM >= b.max.y);
    let best: [number, number] | null = null;
    let bestDistance = Infinity;
    const step = 5;
    for (let py = size.y / 2; py <= depth - size.y / 2; py += step) {
      for (let px = size.x / 2; px <= width - size.x / 2; px += step) {
        const distance = Math.hypot(px - width / 2, py - depth / 2);
        if (distance < bestDistance && free(px, py)) {
          best = [px, py];
          bestDistance = distance;
        }
      }
    }
    // With no room left it stays in the middle, and shows as overlapping for the user to sort out.
    if (best && others.length) o.mesh.position.set(best[0], best[1], 0);
    this.settle(o);
  }

  /** Lay out everything in rows, centred on the plate. */
  arrange(): void {
    const sized = this.objects.map((o) => ({ o, size: new THREE.Box3().setFromObject(o.mesh, true).getSize(new THREE.Vector3()) }));
    sized.sort((a, b) => b.size.y - a.size.y);
    const rows: { items: typeof sized; width: number; depth: number }[] = [];
    let row: (typeof rows)[number] = { items: [], width: 0, depth: 0 };
    for (const s of sized) {
      if (row.items.length && row.width + GAP_MM + s.size.x > this.volume.x) {
        rows.push(row);
        row = { items: [], width: 0, depth: 0 };
      }
      row.width += (row.items.length ? GAP_MM : 0) + s.size.x;
      row.depth = Math.max(row.depth, s.size.y);
      row.items.push(s);
    }
    if (row.items.length) rows.push(row);
    let y = (this.volume.y - rows.reduce((n, r, i) => n + r.depth + (i ? GAP_MM : 0), 0)) / 2;
    for (const r of rows) {
      let x = (this.volume.x - r.width) / 2;
      for (const s of r.items) {
        s.o.mesh.position.x = x + s.size.x / 2;
        s.o.mesh.position.y = y + r.depth / 2;
        x += s.size.x + GAP_MM;
      }
      y += r.depth + GAP_MM;
    }
    for (const o of this.objects) this.settle(o);
    this.onChange();
  }

  /** Items for the server, in the format of POST /slices. */
  layout(): PlateItem[] {
    return this.objects.map((o) => ({ file_id: o.fileId, object: o.object, name: o.name, matrix: o.matrix(), enforce: o.runs(ENFORCE), block: o.runs(BLOCK) }));
  }

  get outOfBounds(): boolean {
    return this.objects.some((o) => o.outOfBounds);
  }

  get painted(): boolean {
    return this.objects.some((o) => o.painted);
  }

  clearPaint(o: PlateObject): void {
    o.paint.fill(NOT_PAINTED);
    this.colourAll(o);
    this.onChange();
    this.render();
  }

  setOverhangs(on: boolean, angle: number): void {
    this.showOverhangs = on;
    this.overhangAngle = angle;
    for (const o of this.allObjects) this.colourAll(o);
    this.render();
  }

  // ---------------------------------------------------------------- bounds and colours

  /** Rest the part on the plate, then check that it fits. */
  private settle(o: PlateObject): void {
    o.mesh.updateMatrixWorld(true);
    const box = new THREE.Box3().setFromObject(o.mesh, true);
    o.mesh.position.z -= box.min.z;
    box.translate(new THREE.Vector3(0, 0, -box.min.z));
    o.mesh.updateMatrixWorld(true);
    const eps = 0.01;
    o.outOfBounds = box.min.x < -eps || box.min.y < -eps || box.max.x > this.volume.x + eps || box.max.y > this.volume.y + eps || box.max.z > this.volume.z + eps;
    o.mesh.material.color.copy(o.outOfBounds ? OUT_OF_BOUNDS : new THREE.Color(0xffffff));
    if (this.showOverhangs) this.colourAll(o);
    this.render();
  }

  private refreshBounds(): void {
    for (const o of this.objects) this.settle(o);
  }

  private colourAll(o: PlateObject): void {
    const colours = o.mesh.geometry.getAttribute("color") as THREE.BufferAttribute;
    for (let f = 0; f < o.paint.length; f++) this.colourFace(o, f, colours);
    colours.needsUpdate = true;
  }

  private overhangScratch = { a: new THREE.Vector3(), b: new THREE.Vector3(), c: new THREE.Vector3(), n: new THREE.Vector3() };

  private colourFace(o: PlateObject, f: number, colours: THREE.BufferAttribute): void {
    let c = BASE;
    if (o.paint[f] === ENFORCE) c = ENFORCE_COLOUR;
    else if (o.paint[f] === BLOCK) c = BLOCK_COLOUR;
    else if (this.showOverhangs && this.isOverhang(o, f)) c = OVERHANG_COLOUR;
    const start = f * 3;
    for (let v = start; v < start + 3; v++) colours.setXYZ(v, c.r, c.g, c.b);
  }

  private isOverhang(o: PlateObject, f: number): boolean {
    const { a, b, c, n } = this.overhangScratch;
    const pos = o.mesh.geometry.getAttribute("position");
    a.fromBufferAttribute(pos, f * 3).applyMatrix4(o.mesh.matrixWorld);
    b.fromBufferAttribute(pos, f * 3 + 1).applyMatrix4(o.mesh.matrixWorld);
    c.fromBufferAttribute(pos, f * 3 + 2).applyMatrix4(o.mesh.matrixWorld);
    // Resting on the plate needs no support.
    if (Math.min(a.z, b.z, c.z) < 0.05) return false;
    n.copy(b).sub(a).cross(c.clone().sub(a)).normalize();
    // Facing down by more than the slicer's overhang angle, measured from straight down.
    return n.z < 0 && Math.acos(Math.min(-n.z, 1)) < THREE.MathUtils.degToRad(90 - this.overhangAngle);
  }

  // ---------------------------------------------------------------- pointer

  private ray(e: PointerEvent): THREE.Intersection | null {
    const r = this.renderer.domElement.getBoundingClientRect();
    this.raycaster.setFromCamera(new THREE.Vector2(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1), this.camera);
    (this.raycaster as THREE.Raycaster & { firstHitOnly?: boolean }).firstHitOnly = true;
    return this.raycaster.intersectObjects(this.objects.map((o) => o.mesh), false)[0] ?? null;
  }

  private objectOf(hit: THREE.Intersection): PlateObject | undefined {
    return this.objects.find((o) => o.mesh === hit.object);
  }

  private get isPaintTool(): boolean {
    return this.tool === "enforce" || this.tool === "block" || this.tool === "erase";
  }

  private pointerDown = (e: PointerEvent) => {
    this.pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    this.downAt = this.pointers.size === 1 && (e.button === 0 || e.button === 2) ? { x: e.clientX, y: e.clientY } : null;
    clearTimeout(this.longPress);
    // On a touch screen, holding a finger still on a part does the job of a right click.
    if (e.pointerType !== "mouse" && this.pointers.size === 1) {
      const at = e;
      this.longPress = window.setTimeout(() => {
        const hit = this.ray(at);
        const o = hit && this.objectOf(hit);
        this.painting = false;
        this.downAt = null;
        if (o) {
          this.select(o);
          this.onPartMenu(o, at.clientX, at.clientY);
        }
      }, 550);
    }
    if (this.isPaintTool) {
      // A second finger means turning the view, so the stroke ends here.
      this.painting = this.pointers.size === 1 && e.button === 0;
      if (this.painting) {
        this.onPaint(this.tool as "enforce" | "block" | "erase");
        this.paintAt(e);
      }
    }
  };

  private pointerMove = (e: PointerEvent) => {
    if (this.pointers.has(e.pointerId)) this.pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (this.downAt && Math.hypot(e.clientX - this.downAt.x, e.clientY - this.downAt.y) > 8) clearTimeout(this.longPress);
    if (!this.isPaintTool) return;
    if (this.painting && this.pointers.size === 1) {
      this.paintAt(e);
    } else if (this.pointers.size === 0 && e.pointerType === "mouse") {
      this.showBrush(this.ray(e));
    }
  };

  private pointerLeave = () => {
    this.brush.visible = false;
    this.render();
  };

  private pointerUp = (e: PointerEvent) => {
    const had = this.pointers.delete(e.pointerId);
    clearTimeout(this.longPress);
    this.painting = false;
    if (e.pointerType !== "mouse") this.brush.visible = false;
    if (!had || !this.downAt || e.type === "pointercancel") return;
    const moved = Math.hypot(e.clientX - this.downAt.x, e.clientY - this.downAt.y) > 5;
    this.downAt = null;
    if (moved || this.toolpaths) return;
    if (e.button === 2) {
      const hit = this.ray(e);
      const o = hit && this.objectOf(hit);
      if (o) {
        this.select(o);
        this.onPartMenu(o, e.clientX, e.clientY);
      }
      return;
    }
    if (this.isPaintTool || this.transform.axis) return;
    const hit = this.ray(e);
    if (this.tool === "flat" && hit?.face) {
      this.layFlat(hit);
      return;
    }
    this.select(hit ? (this.objectOf(hit) ?? null) : null);
  };

  private layFlat(hit: THREE.Intersection): void {
    const o = this.objectOf(hit);
    if (!o || !hit.face) return;
    const normal = hit.face.normal.clone().applyQuaternion(o.mesh.quaternion).normalize();
    o.mesh.quaternion.premultiply(new THREE.Quaternion().setFromUnitVectors(normal, new THREE.Vector3(0, 0, -1)));
    this.settle(o);
    this.select(o);
    this.setTool("select");
  }

  private showBrush(hit: THREE.Intersection | null): void {
    this.brush.visible = !!hit;
    if (hit) {
      this.brush.position.copy(hit.point);
      this.brush.scale.setScalar(this.brushMm);
    }
    this.render();
  }

  private paintAt(e: PointerEvent): void {
    const hit = this.ray(e);
    this.showBrush(hit);
    const o = hit && this.objectOf(hit);
    if (o) this.paintSphere(o, hit.point);
  }

  /** Paint the triangles within the brush that face the viewer. World coordinates. */
  paintSphere(o: PlateObject, point: THREE.Vector3): void {
    const value = this.tool === "enforce" ? ENFORCE : this.tool === "block" ? BLOCK : NOT_PAINTED;
    const bvh = o.mesh.geometry.boundsTree as MeshBVH;
    const centre = o.mesh.worldToLocal(point.clone());
    const radius = this.brushMm / o.mesh.scale.x;
    const sphere = new THREE.Sphere(centre, radius);
    const eye = o.mesh.worldToLocal(this.camera.position.clone());
    const closest = new THREE.Vector3();
    const colours = o.mesh.geometry.getAttribute("color") as THREE.BufferAttribute;
    const normal = new THREE.Vector3();
    const towardsEye = new THREE.Vector3();
    let changed = false;
    bvh.shapecast({
      intersectsBounds: (box) => {
        if (!sphere.intersectsBox(box)) return NOT_INTERSECTED;
        return sphere.containsPoint(box.min) && sphere.containsPoint(box.max) ? CONTAINED : INTERSECTED;
      },
      intersectsTriangle: (tri, f) => {
        if (tri.closestPointToPoint(centre, closest).distanceTo(centre) > radius) return false;
        tri.getNormal(normal);
        // The far side of a thin wall stays as it is.
        if (normal.dot(towardsEye.copy(eye).sub(closest)) <= 0) return false;
        if (o.paint[f] !== value) {
          o.paint[f] = value;
          this.colourFace(o, f, colours);
          changed = true;
        }
        return false;
      },
    });
    if (changed) {
      colours.needsUpdate = true;
      this.onChange();
      this.render();
    }
  }

  // ---------------------------------------------------------------- drawing

  private resize(): void {
    const w = this.container.clientWidth || 1;
    const h = this.container.clientHeight || 1;
    this.renderer.setSize(w, h);
    this.camera.aspect = w / h;
    this.camera.updateProjectionMatrix();
    // The first sizes come through as the page settles, before anyone has turned the view.
    if (!this.viewMoved) this.home();
    this.render();
  }

  render(): void {
    if (this.renderScheduled) return;
    this.renderScheduled = true;
    this.frame = requestAnimationFrame(() => {
      this.renderScheduled = false;
      this.renderer.render(this.scene, this.camera);
    });
  }
}
