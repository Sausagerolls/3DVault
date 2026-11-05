import { type ReactNode, useEffect, useMemo, useRef, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useNavigate, useParams, useSearchParams } from "react-router-dom";
import { api, type Machine, type ModelDetail, type PrintInfo, type ProcessOption, type ProcessSchema, type SliceTask, type SlicerOptions } from "../api";
import { duration, printableFiles } from "../components/Printing";
import { useToast } from "../components/ui";
import { PlateEditor, type PlateObject, type Tool, type Transform } from "../viewer/PlateEditor";
import { FEATURES, parseToolpaths, type ToolpathData } from "../viewer/Toolpaths";

/** What's chosen for one slice, apart from the process settings. */
type Settings = { process: string; filament: string; bed: string };
type EditorScene = {
  plates: { index: number; name: string }[];
  objects: { object: number; name: string; enforce?: number[]; block?: number[] }[];
  items: { object: number; plate: number; matrix: number[] | null }[];
  settings?: ProjectSettings | null;
};
type ProjectSettings = { process: string; printer: string; filament: string; bed: string; values: Record<string, string> };

const TOOLS: { id: Tool; label: string; title: string }[] = [
  { id: "select", label: "Select", title: "Choose a part and turn the view" },
  { id: "move", label: "Move", title: "Drag the arrows to move the selected part" },
  { id: "rotate", label: "Rotate", title: "Drag the rings to turn the selected part" },
  { id: "flat", label: "Lay flat", title: "Tap a face to rest it on the plate" },
];
const PAINT_TOOLS: { id: Tool; label: string; title: string }[] = [
  { id: "enforce", label: "Add supports", title: "Paint where supports must go" },
  { id: "block", label: "Block supports", title: "Paint where supports mustn't go" },
  { id: "erase", label: "Erase", title: "Remove painting" },
];

/** The native apps show this page in a web view and listen for these messages. */
type NativeBridge = { webkit?: { messageHandlers?: { vault?: { postMessage: (m: unknown) => void } } } };
const native = () => (window as unknown as NativeBridge).webkit?.messageHandlers?.vault;

export default function PreparePage() {
  const { id } = useParams();
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const toast = useToast();
  const qc = useQueryClient();
  const embedded = params.has("embed");
  const modelId = Number(id);

  const model = useQuery({ queryKey: ["model", modelId], queryFn: () => api<ModelDetail>(`/models/${modelId}`) });
  const machines = useQuery({ queryKey: ["machines"], queryFn: () => api<Machine[]>("/machines") });
  const [machineId, setMachineId] = useState<number | null>(params.get("machine") ? Number(params.get("machine")) : null);
  const options = useQuery({
    queryKey: ["slicer-options", machineId],
    queryFn: () => api<SlicerOptions>(`/slicer/options?machine_id=${machineId}`),
    enabled: machineId != null,
    retry: false,
  });

  const holder = useRef<HTMLDivElement>(null);
  const editorRef = useRef<PlateEditor | null>(null);
  const [, redraw] = useState(0);
  const [tool, setTool] = useState<Tool>("select");
  const [brush, setBrush] = useState(4);
  const [overhangs, setOverhangs] = useState(false);
  // Settings changed from the process preset. Only these are sent, on top of the preset.
  const [changes, setChanges] = useState<Record<string, string>>({});
  const valueRef = useRef<(key: string) => string>(() => "");
  const [search, setSearch] = useState("");
  const [advanced, setAdvanced] = useState(() => localStorage.getItem("prepare.advanced") !== "0");
  const [settings, setSettings] = useState<Settings | null>(null);
  const [loading, setLoading] = useState(0);
  const [reading, setReading] = useState(0);
  const [projectTick, setProjectTick] = useState(0);
  const platesRef = useRef<{ index: number; name: string }[]>([{ index: 1, name: "" }]);
  const plateRef = useRef(1);
  const [task, setTask] = useState<SliceTask | null>(null);
  const [slicedId, setSlicedId] = useState<number | null>(null);
  const [addFile, setAddFile] = useState("");
  const [toolpaths, setToolpaths] = useState<ToolpathData | null>(null);
  const [features, setFeatures] = useState<number[]>([]);
  const [hiddenFeatures, setHiddenFeatures] = useState<Set<number>>(new Set());
  const [layer, setLayer] = useState(0);
  const [plates, setPlates] = useState<{ index: number; name: string }[]>([{ index: 1, name: "" }]);
  const [plate, setPlate] = useState(1);
  const [partMenu, setPartMenu] = useState<{ part: PlateObject; x: number; y: number } | null>(null);
  // Copies on plates not looked at yet. Big projects only load what's being looked at.
  const waiting = useRef(new Map<number, { fileId: number; object: number; name: string; matrix: number[] | null; enforce?: number[]; block?: number[] }[]>());
  // A project's settings, until the presets they're compared with have loaded.
  const project = useRef<ProjectSettings | null>(null);
  const projectValues = useRef<{ process: string; values: Record<string, string>; note: string } | null>(null);
  const editor = editorRef.current;
  const selected = editor?.selected ?? null;

  const parts = useMemo(() => {
    if (!model.data) return [];
    const sliced = new Set(["gcode", "bgcode"]);
    return printableFiles(model.data).filter((f) => !sliced.has(f.ext) && !(f.ext === "3mf" && f.meta.sliced));
  }, [model.data]);

  useEffect(() => {
    if (!holder.current) return;
    const e = new PlateEditor(holder.current);
    e.onChange = () => redraw((n) => n + 1);
    e.onPartMenu = (part, x, y) => setPartMenu({ part, x, y });
    // Painting only counts if supports are on, so turn them on at the first stroke.
    e.onPaint = (kind) => {
      if (kind !== "erase") setChanges((c) => ({ ...c, ...supportsForPainting(valueRef.current) }));
    };
    editorRef.current = e;
    redraw((n) => n + 1);
    return () => {
      e.dispose();
      editorRef.current = null;
    };
  }, []);

  /** Load a plate's waiting copies. A project's parts stay arranged as they were in it. */
  const loadPlate = async (index: number) => {
    const e = editorRef.current;
    const copies = waiting.current.get(index);
    if (!e || !copies?.length) return;
    waiting.current.delete(index);
    const wasEmpty = !e.allObjects.some((o) => o.plate === index);
    setLoading((n) => n + 1);
    try {
      const added: PlateObject[] = [];
      for (const c of copies) added.push(await e.add(c.fileId, c.object, c.name, index, wasEmpty ? c.matrix : null, c));
      if (wasEmpty) e.centreGroup(added.filter((_, i) => copies[i].matrix));
      if (added.length === 1 && index === plateRef.current) e.select(added[0]);
    } catch (err) {
      toast((err as Error).message, true);
    } finally {
      setLoading((n) => n - 1);
    }
  };

  const addPart = async (fileId: number, first = false) => {
    const f = model.data?.files.find((x) => x.id === fileId);
    if (!editorRef.current || !f) return;
    setReading((n) => n + 1);
    try {
      const scene = await api<EditorScene>(`/files/${fileId}/editor-scene`);
      if (first && scene.settings) project.current = scene.settings;
      setProjectTick((n) => n + 1);
      // A project with its own plates keeps them: first in an empty editor, else after the others.
      const offset = scene.plates.length > 1 && !first ? Math.max(...platesRef.current.map((p) => p.index)) : 0;
      const target = (index: number) => (scene.plates.length > 1 ? index + offset : plateRef.current);
      if (scene.plates.length > 1) {
        const next = first ? scene.plates : [...platesRef.current, ...scene.plates.map((p) => ({ ...p, index: p.index + offset }))];
        platesRef.current = next;
        setPlates(next);
      }
      for (const item of scene.items) {
        const index = target(item.plate);
        const list = waiting.current.get(index) ?? [];
        const obj = scene.objects[item.object];
        list.push({ fileId, object: item.object, name: obj?.name ?? f.rel_path, matrix: item.matrix, enforce: obj?.enforce, block: obj?.block });
        waiting.current.set(index, list);
      }
      const start = scene.plates.length > 1 ? target(scene.plates[0].index) : plateRef.current;
      switchPlate(start);
      await loadPlate(start);
    } catch (e) {
      toast(`${f.rel_path}: ${(e as Error).message}`, true);
    } finally {
      setReading((n) => n - 1);
    }
  };

  const switchPlate = (index: number) => {
    plateRef.current = index;
    setPlate(index);
    setPartMenu(null);
    editorRef.current?.setPlate(index);
    loadPlate(index);
  };

  const newPlate = () => {
    const index = Math.max(...platesRef.current.map((p) => p.index)) + 1;
    const next = [...platesRef.current, { index, name: "" }];
    platesRef.current = next;
    setPlates(next);
    return index;
  };

  const sendToPlate = async (part: PlateObject, index: number) => {
    setPartMenu(null);
    // Anything waiting on that plate has to be there first, for the part to find a free spot.
    await loadPlate(index);
    editorRef.current?.moveToPlate(part, index);
  };

  const plateLabel = (p: { index: number; name: string }) => (p.name ? `${p.index} · ${p.name}` : `Plate ${p.index}`);

  // Put the requested files on the plate, or the first file there is.
  const started = useRef(false);
  useEffect(() => {
    if (started.current || !parts.length || !editor) return;
    started.current = true;
    const asked = (params.get("files") ?? "").split(",").map(Number).filter((x) => parts.some((p) => p.id === x));
    (async () => {
      const ids = asked.length ? asked : [parts[0].id];
      for (let i = 0; i < ids.length; i++) await addPart(ids[i], i === 0);
    })();
  }, [parts, editor]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (machineId == null && machines.data?.length) {
      const on = machines.data.filter((x) => x.enabled);
      setMachineId((on.find((x) => x.slicer_printer) ?? on[0])?.id ?? null);
    }
  }, [machines.data, machineId]);

  useEffect(() => {
    const o = options.data;
    if (!o) return;
    if (o.volume && editorRef.current) editorRef.current.setVolume(o.volume);
    setSettings((old) => ({
      process: old?.process && o.processes.some((p) => p.name === old.process) ? old.process : o.default_process || o.processes[0]?.name || "",
      filament: old?.filament && o.filaments.some((f) => f.name === old.filament) ? old.filament : o.default_filament || o.filaments[0]?.name || "",
      bed: o.default_bed_type || o.bed_types[0] || "",
    }));
  }, [options.data]);

  const schema = useQuery({ queryKey: ["process-schema"], queryFn: () => api<ProcessSchema>("/slicer/process-schema"), staleTime: Infinity, retry: false });
  const preset = useQuery({
    queryKey: ["process-values", settings?.process],
    queryFn: () => api<Record<string, string>>(`/slicer/process-values?name=${encodeURIComponent(settings!.process)}`),
    enabled: !!settings?.process,
  });
  // Start from what an opened project was set to, on this printer's presets where they match.
  useEffect(() => {
    const p = project.current;
    const o = options.data;
    if (!p || !o || !settings) return;
    project.current = null;
    const process = o.processes.some((x) => x.name === p.process) ? p.process : settings.process;
    setSettings({
      process,
      filament: o.filaments.some((x) => x.name === p.filament) ? p.filament : settings.filament,
      bed: o.bed_types.includes(p.bed) ? p.bed : settings.bed,
    });
    // Line widths suit one nozzle size, so a project for another keeps this printer's.
    const nozzle = (name: string) => /([\d.]+) nozzle/.exec(name)?.[1];
    const otherNozzle = !!nozzle(p.printer) && !!nozzle(o.printer) && nozzle(p.printer) !== nozzle(o.printer);
    const values = Object.fromEntries(Object.entries(p.values).filter(([key]) => !(otherNozzle && key.endsWith("line_width"))));
    const other = p.printer && p.printer !== o.printer
      ? ` It was made for ${p.printer}, so check them for this printer.${otherNozzle ? " Line widths stay as this printer's." : ""}`
      : "";
    projectValues.current = { process, values, note: other };
  }, [options.data, projectTick, !!settings]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    const p = projectValues.current;
    if (!p || !preset.data || settings?.process !== p.process) return;
    projectValues.current = null;
    const differ: Record<string, string> = {};
    for (const [key, v] of Object.entries(p.values)) if (preset.data[key] !== v) differ[key] = v;
    setChanges(differ);
    const n = Object.keys(differ).length;
    if (n) toast(`Kept this project's settings: ${n} differ from the preset.${p.note}`);
  }, [preset.data, settings?.process]); // eslint-disable-line react-hooks/exhaustive-deps

  const value = (key: string): string => changes[key] ?? preset.data?.[key] ?? "";
  valueRef.current = value;
  const setValue = (key: string, v: string) =>
    setChanges((c) => {
      const next = { ...c };
      if (v === preset.data?.[key]) delete next[key];
      else next[key] = v;
      return next;
    });

  useEffect(() => {
    if (editor) editor.brushMm = brush;
  }, [brush, editor]);
  useEffect(() => {
    if (editor) editor.setOverhangs(overhangs, Number(value("support_threshold_angle")) || 30);
  }, [overhangs, value("support_threshold_angle"), editor]); // eslint-disable-line react-hooks/exhaustive-deps

  // The sliced print replaces the parts in the 3D view until going back to editing.
  useEffect(() => {
    if (slicedId == null) return;
    let stale = false;
    const lineWidth = Number(value("line_width")) || 0.42;
    (async () => {
      try {
        const res = await fetch(`/api/v1/files/${slicedId}/toolpaths-data`);
        if (!res.ok) throw new Error(`Couldn't load the sliced print (${res.status})`);
        const data = parseToolpaths(await res.arrayBuffer());
        if (stale || !editorRef.current) return;
        setToolpaths(data);
        setFeatures(editorRef.current.showToolpaths(data, lineWidth));
        setHiddenFeatures(new Set());
        setLayer(data.layers - 1);
      } catch (e) {
        if (!stale) toast((e as Error).message, true);
      }
    })();
    return () => {
      stale = true;
      setToolpaths(null);
      editorRef.current?.hideToolpaths();
    };
  }, [slicedId]); // eslint-disable-line react-hooks/exhaustive-deps

  const showLayer = (n: number) => {
    const top = (toolpaths?.layers ?? 1) - 1;
    const next = Math.min(Math.max(n, 0), top);
    setLayer(next);
    editor?.setToolpathLayer(next);
  };

  const toggleFeature = (f: number) => {
    const next = new Set(hiddenFeatures);
    if (next.has(f)) next.delete(f);
    else next.add(f);
    setHiddenFeatures(next);
    editor?.setToolpathFeature(f, !next.has(f));
  };

  const set = (patch: Partial<Settings>) => setSettings((s) => (s ? { ...s, ...patch } : s));
  const pick = (t: Tool) => {
    setTool(t);
    editor?.setTool(t);
  };

  const close = () => {
    const n = native();
    if (n) n.postMessage({ type: "close" });
    else navigate(`/models/${modelId}`);
  };

  const slice = async () => {
    if (!editor || !settings || machineId == null) return;
    const layout = editor.layout();
    const processValues = changes;
    try {
      let t = await api<SliceTask>("/slices", {
        method: "POST",
        json: {
          file_ids: [...new Set(layout.map((x) => x.file_id))],
          machine_id: machineId,
          process: settings.process,
          filaments: [settings.filament],
          overrides: {
            bed_type: settings.bed,
            process_values: processValues,
            layout,
          },
        },
      });
      setTask(t);
      while (t.state === "queued" || t.state === "slicing") {
        await new Promise((r) => setTimeout(r, 2000));
        t = await api<SliceTask>(`/slices/${t.id}`);
        setTask(t);
      }
      if (t.state === "done" && t.output_file_id) {
        setSlicedId(t.output_file_id);
        setTask(null);
        qc.invalidateQueries({ queryKey: ["model"] });
      }
    } catch (e) {
      toast((e as Error).message, true);
      setTask(null);
    }
  };

  const toPrint = () => {
    const n = native();
    if (n) n.postMessage({ type: "sliced", file_id: slicedId });
    else navigate(`/models/${modelId}`, { state: { print: slicedId } });
  };

  const machine = machines.data?.find((x) => x.id === machineId);
  const t = selected && editor ? editor.getTransform(selected) : null;
  const setT = (patch: Partial<Transform>) => {
    if (selected && editor) editor.setTransform(selected, patch);
  };
  const busy = task != null && task.state !== "failed";
  const empty = !editor?.objects.length || waiting.current.has(plate);
  const blockReason = empty ? (loading ? "Loading parts…" : "Add a part to this plate first, or send one here.") : editor?.outOfBounds ? "A part is outside the printable area. Move it or make it smaller." : options.error ? (options.error as Error).message : "";

  return (
    <div className="prepare">
      <header className="prepare-bar">
        <button onClick={close}>{embedded ? "Close" : "Back"}</button>
        <strong className="ellipsis">{model.data?.name ?? "Prepare"}</strong>
        <span className="spacer" />
        {slicedId == null && <div className="segment">
          {TOOLS.map((x) => <button key={x.id} title={x.title} className={tool === x.id ? "active" : ""} onClick={() => pick(x.id)}>{x.label}</button>)}
        </div>}
        {slicedId == null && <div className="segment">
          {PAINT_TOOLS.map((x) => <button key={x.id} title={x.title} className={tool === x.id ? "active" : ""} onClick={() => pick(x.id)}>{x.label}</button>)}
        </div>}
        <button title="Back to the starting view" onClick={() => editor?.home()}>Reset view</button>
      </header>
      <div className="prepare-main">
        <div className="prepare-view">
          <div ref={holder} style={{ position: "absolute", inset: 0 }} />
          {!!reading && <div className="prepare-note">Reading the file. A big project can take several minutes the first time…</div>}
          {!reading && !!loading && <div className="prepare-note">Loading parts…</div>}
          {slicedId == null && (
            <div className="prepare-plates" role="tablist" aria-label="Build plates">
              {plates.map((p) => (
                <button key={p.index} role="tab" aria-selected={p.index === plate} className={`small ${p.index === plate ? "active" : ""}`} onClick={() => switchPlate(p.index)}>
                  {plateLabel(p)}
                </button>
              ))}
              <button className="small" title="Add a build plate" aria-label="Add a build plate" onClick={() => switchPlate(newPlate())}>+</button>
            </div>
          )}
          {partMenu && editor && (
            <PartMenu
              at={partMenu}
              plates={plates.filter((p) => p.index !== plate)}
              label={plateLabel}
              onSend={(index) => sendToPlate(partMenu.part, index)}
              onNewPlate={() => sendToPlate(partMenu.part, newPlate())}
              onDuplicate={() => { setPartMenu(null); editor.duplicate(partMenu.part); }}
              onRemove={() => { setPartMenu(null); editor.remove(partMenu.part); }}
              onClose={() => setPartMenu(null)}
            />
          )}
          {slicedId != null && !toolpaths && <div className="prepare-note">Loading the sliced print…</div>}
          {toolpaths && (
            <div className="prepare-layers">
              <button className="small" aria-label="Down a layer" disabled={layer <= 0} onClick={() => showLayer(layer - 1)}>−</button>
              <input aria-label="Layer" type="range" min={0} max={toolpaths.layers - 1} value={layer} onChange={(e) => showLayer(Number(e.target.value))} />
              <button className="small" aria-label="Up a layer" disabled={layer >= toolpaths.layers - 1} onClick={() => showLayer(layer + 1)}>+</button>
              <span className="prepare-layer-label">Layer {layer + 1} of {toolpaths.layers} · {toolpaths.z[layer].toFixed(2)} mm</span>
            </div>
          )}
          {["enforce", "block", "erase"].includes(tool) && (
            <div className="prepare-brush">
              <label className="row" style={{ gap: 8 }}>
                Brush
                <input type="range" min={1} max={30} step={0.5} value={brush} onChange={(e) => setBrush(Number(e.target.value))} />
                {brush} mm
              </label>
              <span className="dim" style={{ fontSize: 12 }}>Turn the view with two fingers or the right mouse button.</span>
            </div>
          )}
        </div>
        <aside className="prepare-panel">
          {options.error && slicedId == null && <p style={{ margin: 0, color: "#d9822b" }}>{(options.error as Error).message}</p>}
          {slicedId != null ? (
            <SliceResult fileId={slicedId} features={features} hidden={hiddenFeatures} onToggle={toggleFeature} onPrint={toPrint} onBack={() => setSlicedId(null)} />
          ) : (
            <>
              <Group id="parts" title="Parts" summary={editor?.objects.length === 1 ? "1 part" : `${editor?.objects.length ?? 0} parts`} defaultOpen>
                {editor?.objects.map((o) => (
                  <button
                    key={o.id}
                    className={`part ${selected === o ? "active" : ""}`}
                    title={o.name}
                    onClick={() => editor.select(o)}
                    onContextMenu={(e) => {
                      e.preventDefault();
                      editor.select(o);
                      setPartMenu({ part: o, x: e.clientX, y: e.clientY });
                    }}
                  >
                    <span className="ellipsis">{o.name}</span>
                    {o.outOfBounds && <span style={{ color: "var(--danger)" }}>Outside</span>}
                  </button>
                ))}
                {parts.length > 0 && (
                  <select value={addFile} onChange={(e) => { const v = Number(e.target.value); setAddFile(""); if (v) addPart(v); }}>
                    <option value="">Add a part…</option>
                    {parts.map((f) => <option key={f.id} value={f.id}>{f.rel_path}</option>)}
                  </select>
                )}
                <div className="row" style={{ gap: 6, flexWrap: "wrap" }}>
                  <button className="small" disabled={!selected} onClick={() => selected && editor?.duplicate(selected)}>Duplicate</button>
                  <button className="small" disabled={!selected} onClick={() => selected && editor?.remove(selected)}>Remove</button>
                  <button className="small" disabled={empty} onClick={() => editor?.arrange()}>Arrange</button>
                  <button className="small" disabled={!selected?.painted} onClick={() => selected && editor?.clearPaint(selected)}>Clear painting</button>
                </div>
                {t && (
                  <div className="prepare-grid">
                    <Num label="X (mm)" value={t.x} onChange={(x) => setT({ x })} />
                    <Num label="Y (mm)" value={t.y} onChange={(y) => setT({ y })} />
                    <Num label="Scale (%)" value={t.scale} min={1} step={5} onChange={(scale) => setT({ scale })} />
                    <Num label="Turn X (°)" value={t.rx} step={15} onChange={(rx) => setT({ rx })} />
                    <Num label="Turn Y (°)" value={t.ry} step={15} onChange={(ry) => setT({ ry })} />
                    <Num label="Turn Z (°)" value={t.rz} step={15} onChange={(rz) => setT({ rz })} />
                  </div>
                )}
              </Group>

              <Group id="printer" title="Printer" summary={[machine?.name, settings?.process.split(" @")[0]].filter(Boolean).join(" · ")}>
                <label className="field">Printer
                  <select value={machineId ?? ""} disabled={busy} onChange={(e) => setMachineId(Number(e.target.value))}>
                    {machines.data?.filter((x) => x.enabled).map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
                  </select>
                </label>
                {settings && options.data && (
                  <>
                    <label className="field">Process preset
                      <select
                        value={settings.process}
                        onChange={(e) => {
                          if (Object.keys(changes).length) toast("Changed settings went back to the new preset's values");
                          setChanges({});
                          set({ process: e.target.value });
                        }}
                      >
                        {options.data.processes.map((p) => <option key={p.name} value={p.name}>{p.name.split(" @")[0]}</option>)}
                      </select>
                    </label>
                    <label className="field">Filament
                      <select value={settings.filament} onChange={(e) => set({ filament: e.target.value })}>
                        {options.data.filaments.map((f) => <option key={f.name} value={f.name}>{f.name.split(" @")[0]}{f.user ? " (imported)" : ""}</option>)}
                      </select>
                    </label>
                    <label className="field">Build plate
                      <select value={settings.bed} onChange={(e) => set({ bed: e.target.value })}>
                        {options.data.bed_types.map((b) => <option key={b}>{b}</option>)}
                      </select>
                    </label>
                  </>
                )}
              </Group>

              <div className="prepare-search">
                <input type="search" placeholder="Search settings" value={search} onChange={(e) => setSearch(e.target.value)} />
                <label className="row" style={{ gap: 6, flex: "none" }} title="Shows every setting. Off shows only the simple ones, like Orca's Simple mode.">
                  <input
                    type="checkbox"
                    checked={advanced}
                    onChange={(e) => {
                      setAdvanced(e.target.checked);
                      localStorage.setItem("prepare.advanced", e.target.checked ? "1" : "0");
                    }}
                  />
                  Advanced
                </label>
              </div>
              {schema.error && <p style={{ margin: 0, color: "#d9822b" }}>{(schema.error as Error).message}</p>}
              {schema.data && preset.data && (
                <ProcessSettings
                  schema={schema.data}
                  value={value}
                  preset={preset.data}
                  changes={changes}
                  onChange={setValue}
                  search={search}
                  advanced={advanced}
                  extra={{
                    Support: (
                      <label className="row" style={{ gap: 6 }}>
                        <input type="checkbox" checked={overhangs} onChange={(e) => setOverhangs(e.target.checked)} /> Highlight overhangs
                      </label>
                    ),
                  }}
                />
              )}

              <footer className="prepare-actions">
                {task && (
                  <p style={{ margin: 0, color: task.state === "failed" ? "var(--danger)" : undefined }}>
                    {task.state === "failed" ? task.error || "Slicing failed" : `${task.state === "queued" ? "Waiting to slice" : "Slicing…"} ${task.ahead ? `(${task.ahead} ahead)` : ""}`}
                  </p>
                )}
                {!task && blockReason && <p className="dim" style={{ margin: 0, fontSize: 12 }}>{blockReason}</p>}
                {machine && settings && !blockReason && (
                  <p className="faint" style={{ margin: 0, fontSize: 12 }}>
                    Sliced on the server for {machine.name}{Object.keys(changes).length ? `, with ${Object.keys(changes).length} changed ${Object.keys(changes).length === 1 ? "setting" : "settings"}` : ""}.
                  </p>
                )}
                <button className="primary" disabled={!!blockReason || !settings || busy} onClick={slice}>
                  {plates.length > 1 ? `Slice plate ${plate}` : "Slice plate"}
                </button>
              </footer>
            </>
          )}
        </aside>
      </div>
    </div>
  );
}

/** What painting needs: supports on, and if they were off, only where painted. */
function supportsForPainting(value: (key: string) => string): Record<string, string> {
  if (value("enable_support") === "1") return {};
  const type = value("support_type") || "normal(auto)";
  return { enable_support: "1", support_type: type.replace("(auto)", "(manual)") };
}

/** Orca's process settings, page by page, built from the server's list of them. */
function ProcessSettings({ schema, value, preset, changes, onChange, search, advanced, extra }: {
  schema: ProcessSchema;
  value: (key: string) => string;
  preset: Record<string, string>;
  changes: Record<string, string>;
  onChange: (key: string, v: string) => void;
  search: string;
  advanced: boolean;
  extra: Record<string, ReactNode>;
}) {
  const words = search.toLowerCase().split(/\s+/).filter(Boolean);
  const visible = (o: ProcessOption) => {
    if (!advanced && o.mode !== "simple") return false;
    const text = `${o.full_label ?? ""} ${o.label ?? ""} ${o.key} ${o.tooltip ?? ""}`.toLowerCase();
    return words.every((w) => text.includes(w));
  };
  return (
    <>
      {schema.pages.map((page) => {
        const groups = page.groups
          .map((g) => ({ title: g.title, options: g.options.map((k) => schema.options[k]).filter((o) => o && visible(o)) }))
          .filter((g) => g.options.length);
        if (!groups.length) return null;
        const changed = page.groups.flatMap((g) => g.options).filter((k) => k in changes).length;
        return (
          <Group key={page.title} id={page.title.toLowerCase()} title={page.title} summary={changed ? `${changed} changed` : undefined} forceOpen={words.length > 0}>
            {!words.length && extra[page.title]}
            {groups.map((g) => (
              <div key={g.title} className="col" style={{ gap: 6 }}>
                <div className="prepare-subhead">{g.title}</div>
                {g.options.map((o) => (
                  <SettingRow key={o.key} option={o} value={value(o.key)} changed={o.key in changes} onChange={(v) => onChange(o.key, v)} onReset={() => onChange(o.key, preset[o.key] ?? "")} />
                ))}
              </div>
            ))}
          </Group>
        );
      })}
    </>
  );
}

function SettingRow({ option: o, value, changed, onChange, onReset }: { option: ProcessOption; value: string; changed: boolean; onChange: (v: string) => void; onReset: () => void }) {
  const [help, setHelp] = useState(false);
  const label = o.full_label || o.label || o.key;
  const out = (o.type === "int" || o.type === "float" || o.type === "percent" || o.type === "float_or_percent") && value !== "" && !isValid(o, value);
  let control: ReactNode;
  if (o.type === "bool") {
    control = <input type="checkbox" checked={value === "1"} onChange={(e) => onChange(e.target.checked ? "1" : "0")} />;
  } else if (o.type === "enum" && o.choices?.length) {
    control = (
      <select value={value} onChange={(e) => onChange(e.target.value)}>
        {!o.choices.some((c) => c.value === value) && <option value={value}>{value}</option>}
        {o.choices.map((c) => <option key={c.value} value={c.value}>{c.label}</option>)}
      </select>
    );
  } else if (o.multiline) {
    control = <textarea rows={3} value={value} onChange={(e) => onChange(e.target.value)} />;
  } else {
    const percent = o.type === "percent";
    control = (
      <span className="prepare-input">
        <input
          type="text"
          inputMode={o.type === "string" ? "text" : "decimal"}
          className={out ? "invalid" : ""}
          value={percent ? value.replace(/%$/, "") : value}
          onChange={(e) => onChange(percent ? `${e.target.value}%` : e.target.value)}
        />
        {(percent || o.unit) && <span className="faint">{percent ? "%" : o.unit}</span>}
      </span>
    );
  }
  return (
    <div className={`prepare-setting ${o.multiline ? "wide" : ""}`}>
      <button className={`prepare-setting-label ${changed ? "changed" : ""}`} title={o.tooltip} onClick={() => setHelp(!help)}>{label}</button>
      <div className="prepare-setting-control">
        {control}
        <button className="prepare-reset" style={{ visibility: changed ? "visible" : "hidden" }} title="Back to the preset's value" aria-label={`Reset ${label}`} onClick={onReset}>↺</button>
      </div>
      {help && o.tooltip && <p className="prepare-help">{o.tooltip}</p>}
    </div>
  );
}

function isValid(o: ProcessOption, v: string): boolean {
  const n = Number(v.replace(/%$/, ""));
  if (v.trim() === "" || !Number.isFinite(n)) return false;
  if (o.type === "int" && !Number.isInteger(n)) return false;
  if (o.type !== "percent" && o.type !== "float_or_percent" && v.endsWith("%")) return false;
  return !(o.min != null && n < o.min) && !(o.max != null && n > o.max);
}

/** Which groups are open is remembered on this device. */
const OPEN_KEY = "prepare.groups";
const savedGroups = (): Record<string, boolean> => {
  try {
    return JSON.parse(localStorage.getItem(OPEN_KEY) ?? "{}");
  } catch {
    return {};
  }
};

/** A collapsible group of settings. Its summary says what's chosen while it's closed. */
function Group({ id, title, summary, defaultOpen, forceOpen, children }: { id: string; title: string; summary?: string; defaultOpen?: boolean; forceOpen?: boolean; children: ReactNode }) {
  const [saved, setOpen] = useState(savedGroups()[id] ?? !!defaultOpen);
  const open = saved || !!forceOpen;
  const toggle = () => {
    setOpen(!saved);
    const value = JSON.stringify({ ...savedGroups(), [id]: !saved });
    localStorage.setItem(OPEN_KEY, value);
    // The apps' web views forget their storage, so the app keeps this and hands it back next time.
    native()?.postMessage({ type: "groups", value });
  };
  return (
    <section className={`prepare-group ${open ? "open" : ""}`}>
      <button className="prepare-group-head" aria-expanded={open} onClick={toggle}>
        <span className="prepare-chevron" aria-hidden>›</span>
        <span className="prepare-group-title">{title}</span>
        {!open && summary && <span className="prepare-group-summary ellipsis">{summary}</span>}
      </button>
      {open && <div className="col prepare-group-body">{children}</div>}
    </section>
  );
}

/** The menu for a part, from a right click or long press. */
function PartMenu({ at, plates, label, onSend, onNewPlate, onDuplicate, onRemove, onClose }: {
  at: { x: number; y: number };
  plates: { index: number; name: string }[];
  label: (p: { index: number; name: string }) => string;
  onSend: (index: number) => void;
  onNewPlate: () => void;
  onDuplicate: () => void;
  onRemove: () => void;
  onClose: () => void;
}) {
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const away = (e: PointerEvent) => {
      if (!box.current?.contains(e.target as Node)) onClose();
    };
    const key = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("pointerdown", away, true);
    window.addEventListener("keydown", key);
    return () => {
      window.removeEventListener("pointerdown", away, true);
      window.removeEventListener("keydown", key);
    };
  }, [onClose]);
  // Stays on the screen when opened near an edge.
  const left = Math.min(at.x, window.innerWidth - 230);
  const top = Math.min(at.y, window.innerHeight - 90 - (plates.length + 3) * 32);
  return (
    <div ref={box} className="prepare-menu" role="menu" style={{ left, top: Math.max(top, 8) }}>
      <div className="prepare-menu-head">Send to plate</div>
      {plates.map((p) => <button key={p.index} role="menuitem" onClick={() => onSend(p.index)}>{label(p)}</button>)}
      <button role="menuitem" onClick={onNewPlate}>New plate</button>
      <hr />
      <button role="menuitem" onClick={onDuplicate}>Duplicate</button>
      <button role="menuitem" className="danger" onClick={onRemove}>Remove</button>
    </div>
  );
}

function Num({ label, value, onChange, min, max, step }: { label: string; value: number; onChange: (n: number) => void; min?: number; max?: number; step?: number }) {
  const shown = Math.round(value * 100) / 100;
  // Keep what's being typed, so a half-typed number isn't overwritten.
  const [text, setText] = useState(String(shown));
  useEffect(() => setText(String(shown)), [shown]);
  return (
    <label className="field">
      {label}
      <input
        type="number" inputMode="decimal" value={text} min={min} max={max} step={step ?? 1}
        onChange={(e) => {
          setText(e.target.value);
          const n = Number(e.target.value);
          if (e.target.value !== "" && Number.isFinite(n)) onChange(n);
        }}
      />
    </label>
  );
}

/** Stats and what to show of a sliced plate. The 3D view shows the print itself. */
function SliceResult({ fileId, features, hidden, onToggle, onPrint, onBack }: {
  fileId: number;
  features: number[];
  hidden: Set<number>;
  onToggle: (feature: number) => void;
  onPrint: () => void;
  onBack: () => void;
}) {
  const info = useQuery({ queryKey: ["print-info", fileId], queryFn: () => api<PrintInfo>(`/files/${fileId}/print-info`) });
  const plate = info.data?.plates[0];
  return (
    <section className="col" style={{ gap: 12, paddingTop: 14 }}>
      <h3>Sliced</h3>
      <dl className="kv">
        <dt>Print time</dt>
        <dd>{duration(plate?.time_s) ?? info.data?.print_time ?? "Unknown"}</dd>
        <dt>Filament</dt>
        <dd>{plate?.weight_g != null ? `${plate.weight_g.toFixed(1)} g` : "Unknown"}</dd>
      </dl>
      <div className="col" style={{ gap: 6 }}>
        {FEATURES.filter((f) => features.includes(f.id)).map((f) => (
          <label key={f.id} className="row" style={{ gap: 8 }}>
            <input type="checkbox" checked={!hidden.has(f.id)} onChange={() => onToggle(f.id)} />
            <span style={{ width: 12, height: 12, borderRadius: 3, background: f.colour, flex: "none" }} />
            {f.name}
          </label>
        ))}
      </div>
      <button className="primary" onClick={onPrint}>Continue to print</button>
      <button onClick={onBack}>Keep editing</button>
    </section>
  );
}
