import { useEffect, useMemo, useRef, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import {
  api,
  type Machine,
  type ModelDetail,
  type PrintInfo,
  type PrintJob,
  type SliceTask,
  type SlicerOptions,
  type ToolpathLayer,
  type ToolpathSummary,
  type VaultFile,
} from "../api";
import { Modal, useToast } from "./ui";

const BASE = "/api/v1";

export const duration = (s: number | null | undefined) => {
  if (s == null) return null;
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return h ? `${h}h ${String(m).padStart(2, "0")}m` : `${m}m`;
};

/** When a print should finish: "17:42" today, "07:10 tomorrow", or "07:10 Wed" further out. */
export const finishTime = (remaining: number, now = new Date()) => {
  const end = new Date(now.getTime() + remaining * 1000);
  const time = end.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  const tomorrow = new Date(now);
  tomorrow.setDate(now.getDate() + 1);
  if (end.toDateString() === now.toDateString()) return time;
  if (end.toDateString() === tomorrow.toDateString()) return `${time} tomorrow`;
  return `${time} ${end.toLocaleDateString([], { weekday: "short" })}`;
};

const STATE_LABELS: Record<string, string> = {
  idle: "Ready", preparing: "Preparing", printing: "Printing", paused: "Paused", finished: "Finished", failed: "Failed",
  offline: "Offline", queued: "Queued", uploading: "Sending", cancelled: "Cancelled", needs_clear: "Clear bed",
};
const STATE_COLORS: Record<string, string> = {
  idle: "var(--ok, #2e9d58)", finished: "var(--ok, #2e9d58)", printing: "var(--accent)", preparing: "var(--accent)", uploading: "var(--accent)",
  paused: "#d9822b", queued: "#d9822b", needs_clear: "#d9822b", failed: "var(--danger)", cancelled: "var(--text-faint)", offline: "var(--text-faint)",
};

export function StateBadge({ state }: { state: string }) {
  const color = STATE_COLORS[state] ?? "var(--text-faint)";
  return (
    <span style={{ color, border: `1px solid ${color}`, borderRadius: 999, padding: "0 8px", fontSize: 12, whiteSpace: "nowrap" }}>
      {STATE_LABELS[state] ?? state}
    </span>
  );
}

const SLICED = new Set(["gcode", "bgcode"]);
const SLICEABLE = new Set(["stl", "obj", "3mf", "step", "stp", "amf"]);
const isSliced = (f: VaultFile) => SLICED.has(f.ext) || (f.ext === "3mf" && !!f.meta.sliced);

/** Files on a model that can be printed: sliced first, then ones the server can slice. */
export function printableFiles(m: ModelDetail): VaultFile[] {
  const sliced = m.files.filter(isSliced);
  return [...sliced, ...m.files.filter((f) => SLICEABLE.has(f.ext) && f.kind !== "photo" && !sliced.includes(f))];
}

/* ---------------------------------------------------------------- printers page */

export function PrintersPage() {
  const machines = useQuery({ queryKey: ["machines"], queryFn: () => api<Machine[]>("/machines"), refetchInterval: 2000 });
  return (
    <div className="page narrow">
      <h1 style={{ marginBottom: 16 }}>Printers</h1>
      {machines.data && !machines.data.length && (
        <p className="dim">
          No printers yet. An admin can add them in <Link to="/settings" className="link">Settings › Printers</Link>.
        </p>
      )}
      <div className="col" style={{ gap: 16 }}>
        {machines.data?.map((m) => <PrinterCard key={m.id} m={m} />)}
      </div>
    </div>
  );
}

function PrinterCard({ m }: { m: Machine }) {
  const toast = useToast();
  const qc = useQueryClient();
  const [showQueue, setShowQueue] = useState(false);
  const s = m.status;
  const job = m.active_job;
  const busy = ["preparing", "printing", "paused"].includes(s.state);
  const act = async (path: string, confirm?: string) => {
    if (confirm && !window.confirm(confirm)) return;
    try {
      await api(`/machines/${m.id}/${path}`, { method: "POST" });
      qc.invalidateQueries({ queryKey: ["machines"] });
    } catch (e) {
      toast((e as Error).message, true);
    }
  };
  const temp = (t?: { temp: number | null; target: number | null }) =>
    t?.temp == null ? "–" : `${Math.round(t.temp)}°${t.target ? ` / ${Math.round(t.target)}°` : ""}`;
  return (
    <section className="panel col">
      <div className="row">
        <h2 className="grow">{m.name}</h2>
        <StateBadge state={m.enabled ? (m.needs_clear && !busy ? "needs_clear" : s.state) : "offline"} />
        <span className="dim" style={{ fontSize: 13 }}>
          Nozzle {temp(s.nozzle)} · Bed {temp(s.bed)}
        </span>
      </div>
      {m.has_camera && s.state !== "offline" && <Camera id={m.id} />}
      {job ? (
        <div className="col" style={{ gap: 6 }}>
          <div className="row">
            {job.model_id ? (
              <Link to={`/models/${job.model_id}`} className="link grow ellipsis">
                {job.model_name}
              </Link>
            ) : (
              <span className="grow ellipsis">{job.model_name}</span>
            )}
            <strong>{Math.round(s.progress ?? job.progress)}%</strong>
          </div>
          <progress max={100} value={s.progress ?? job.progress} style={{ width: "100%" }} />
          <div className="row dim" style={{ fontSize: 13 }}>
            {s.layer != null && s.total_layers != null && <span>Layer {s.layer} of {s.total_layers}</span>}
            <span className="spacer" />
            {busy && duration(s.remaining_s) && <span>{duration(s.remaining_s)} left</span>}
          </div>
          {s.state === "printing" && !!s.remaining_s && s.remaining_s > 0 && (
            <div className="dim" style={{ fontSize: 13, textAlign: "right" }}>Done about {finishTime(s.remaining_s)}</div>
          )}
          <div className="row" style={{ gap: 8 }}>
            {s.state === "paused" ? (
              <button className="small primary" onClick={() => act("resume")}>Resume</button>
            ) : (
              <button className="small" disabled={s.state !== "printing"} onClick={() => act("pause")}>Pause</button>
            )}
            <button className="small danger" onClick={() => act("cancel", "Stop this print? It can't be resumed.")}>Stop</button>
          </div>
        </div>
      ) : (
        s.message && <p className="dim" style={{ margin: 0, color: s.state === "failed" ? "var(--danger)" : undefined }}>{s.message}</p>
      )}
      {m.needs_clear && (
        <div className="row" style={{ gap: 8 }}>
          <span className="grow" style={{ color: "#d9822b" }}>Clear the bed before the next print starts.</span>
          <button className="small primary" disabled={busy} onClick={() => act("bed-cleared")}>Bed cleared</button>
        </div>
      )}
      <button className="small ghost" style={{ alignSelf: "flex-start" }} onClick={() => setShowQueue(!showQueue)}>
        {m.queued ? `${m.queued} waiting in queue` : "Queue and history"} {showQueue ? "▾" : "▸"}
      </button>
      {showQueue && <JobList machineId={m.id} />}
    </section>
  );
}

function Camera({ id }: { id: number }) {
  const [tick, setTick] = useState(0);
  useEffect(() => {
    const t = setInterval(() => setTick((n) => n + 1), 3000);
    return () => clearInterval(t);
  }, []);
  return <img src={`${BASE}/machines/${id}/camera?t=${tick}`} alt="Printer camera" style={{ width: "100%", maxHeight: 360, objectFit: "contain", borderRadius: 8, background: "#000" }} />;
}

export function JobList({ machineId, modelId }: { machineId?: number; modelId?: number }) {
  const qs = machineId != null ? `machine_id=${machineId}` : `model_id=${modelId}`;
  const jobs = useQuery({ queryKey: ["jobs", qs], queryFn: () => api<PrintJob[]>(`/jobs?${qs}`), refetchInterval: 4000 });
  const qc = useQueryClient();
  if (!jobs.data?.length) return <p className="dim" style={{ margin: 0 }}>No prints yet.</p>;
  return (
    <table className="list">
      <tbody>
        {jobs.data.map((j) => (
          <tr key={j.id}>
            <td className="ellipsis">
              {machineId != null && j.model_id ? <Link className="link" to={`/models/${j.model_id}`}>{j.model_name}</Link> : machineId != null ? j.model_name : j.machine_name}
              {j.error && <div style={{ color: "var(--danger)", fontSize: 12 }}>{j.error}</div>}
            </td>
            <td className="dim" style={{ fontSize: 12, whiteSpace: "nowrap" }}>
              {[j.external ? "Started outside 3DVault" : j.user, new Date(j.finished_at ?? j.created_at).toLocaleString()].filter(Boolean).join(" · ")}
            </td>
            <td style={{ textAlign: "right" }}>
              {j.state === "queued" ? (
                <button className="small" onClick={async () => (await api(`/jobs/${j.id}/cancel`, { method: "POST" }), qc.invalidateQueries({ queryKey: ["jobs"] }))}>
                  Remove
                </button>
              ) : (
                <StateBadge state={j.state} />
              )}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

/* ---------------------------------------------------------------- print dialog */

type Settings = {
  process: string; filament: string; bed: string; slot: number;
  layer_height: number; infill: number; walls: number; supports: boolean; support_type: string; brim: string; scale: number;
};

export function PrintDialog({ m, initialFile, onClose }: { m: ModelDetail; initialFile?: number; onClose: () => void }) {
  const toast = useToast();
  const qc = useQueryClient();
  const files = useMemo(() => printableFiles(m), [m]);
  const parts = files.filter((f) => ["stl", "obj", "step", "stp", "amf"].includes(f.ext));
  const [source, setSource] = useState(initialFile ? `f${initialFile}` : files[0] ? `f${files[0].id}` : "");
  const fileId = source.startsWith("f") ? Number(source.slice(1)) : null;
  const machines = useQuery({ queryKey: ["machines"], queryFn: () => api<Machine[]>("/machines"), refetchInterval: 3000 });
  const [machineId, setMachineId] = useState<number | null>(null);
  const machine = machines.data?.find((x) => x.id === machineId);
  const [slicedId, setSlicedId] = useState<number | null>(null);
  const [task, setTask] = useState<SliceTask | null>(null);
  const [plate, setPlate] = useState(1);
  const [mapping, setMapping] = useState<Record<number, number>>({});
  const [sending, setSending] = useState(false);
  const [preview, setPreview] = useState(false);
  const [settings, setSettings] = useState<Settings | null>(null);

  const infoFile = slicedId ?? fileId;
  const info = useQuery({
    queryKey: ["print-info", infoFile],
    queryFn: () => api<PrintInfo>(`/files/${infoFile}/print-info`),
    enabled: infoFile != null,
  });
  const options = useQuery({
    queryKey: ["slicer-options", machineId],
    queryFn: () => api<SlicerOptions>(`/slicer/options?machine_id=${machineId}`),
    enabled: machineId != null,
    retry: false,
  });

  useEffect(() => {
    if (machineId == null && machines.data?.length) {
      const enabled = machines.data.filter((x) => x.enabled);
      const ready = enabled.find((x) => !x.needs_clear && ["idle", "finished"].includes(x.status.state));
      setMachineId((ready ?? enabled[0])?.id ?? null);
    }
  }, [machines.data, machineId]);
  useEffect(() => {
    setSlicedId(null);
    setTask(null);
    setMapping({});
  }, [source]);
  useEffect(() => {
    const o = options.data;
    if (!o) return;
    const d = o.defaults;
    const slot = machine?.status.ams[0];
    setSettings((old) => ({
      process: old?.process && o.processes.some((p) => p.name === old.process) ? old.process : o.default_process || o.processes[0]?.name || "",
      filament: old?.filament && o.filaments.some((f) => f.name === old.filament) ? old.filament : o.default_filament || o.filaments[0]?.name || "",
      bed: o.default_bed_type || o.bed_types[0] || "",
      slot: old?.slot ?? (slot ? slot.unit * 4 + slot.slot : -1),
      layer_height: d.layer_height ?? 0.2,
      infill: d.sparse_infill_density ?? 15,
      walls: d.wall_loops ?? 2,
      supports: d.enable_support,
      support_type: d.support_type || "tree(auto)",
      brim: d.brim_type || "auto_brim",
      scale: old?.scale ?? 100,
    }));
  }, [options.data]); // eslint-disable-line react-hooks/exhaustive-deps

  const i = info.data;
  const needsSlice = slicedId == null && (source === "all" || (i != null && i.format == null));
  const plateInfo = i?.plates.find((p) => p.index === plate);
  const willQueue = !!machine && (machine.needs_clear || machine.queued > 0 || !!machine.active_job || ["preparing", "printing", "paused"].includes(machine.status.state));
  const printFile = slicedId ?? (i?.format ? i.file_id : null);
  const compatible = !!i && i.machines.some((x) => x.id === machineId && x.compatible);
  const ams = machine?.status.ams ?? [];

  // Default AMS mapping: same material, closest colour.
  useEffect(() => {
    if (!plateInfo || !ams.length) return;
    const next: Record<number, number> = {};
    for (const f of plateInfo.filaments) {
      if (slicedId != null && settings && settings.slot >= 0 && plateInfo.filaments.length === 1) {
        next[f.id] = settings.slot;
        continue;
      }
      const pool = ams.filter((a) => a.type.toLowerCase() === f.type.toLowerCase());
      const best = (pool.length ? pool : ams).reduce((a, b) => (colourDistance(a.color, f.color) <= colourDistance(b.color, f.color) ? a : b));
      next[f.id] = best.unit * 4 + best.slot;
    }
    setMapping(next);
  }, [plateInfo?.index, i?.file_id, machineId]); // eslint-disable-line react-hooks/exhaustive-deps

  const slice = async () => {
    if (!settings || machineId == null) return;
    const ids = source === "all" ? parts.map((f) => f.id) : [fileId!];
    const slot = ams.find((a) => a.unit * 4 + a.slot === settings.slot);
    try {
      let t = await api<SliceTask>("/slices", {
        method: "POST",
        json: {
          file_ids: ids, machine_id: machineId, process: settings.process, filaments: [settings.filament],
          overrides: {
            layer_height: settings.layer_height, sparse_infill_density: settings.infill, wall_loops: settings.walls,
            enable_support: settings.supports, support_type: settings.support_type, brim_type: settings.brim,
            bed_type: settings.bed, scale: settings.scale / 100, ...(slot ? { filament_colours: [slot.color] } : {}),
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
        setPlate(1);
        qc.invalidateQueries({ queryKey: ["model"] });
      }
    } catch (e) {
      toast((e as Error).message, true);
      setTask(null);
    }
  };

  const send = async () => {
    if (printFile == null || machineId == null) return;
    setSending(true);
    const count = Math.max(0, ...(plateInfo?.filaments.map((f) => f.id) ?? []));
    const amsMapping = count && Object.keys(mapping).length ? Array.from({ length: count }, (_, k) => mapping[k + 1] ?? -1) : [];
    try {
      const job = await api<PrintJob>("/jobs", { method: "POST", json: { file_id: printFile, machine_id: machineId, plate, ams_mapping: amsMapping } });
      toast(willQueue ? `Added to the ${job.machine_name} queue` : `Sending to ${job.machine_name}`);
      qc.invalidateQueries({ queryKey: ["machines"] });
      onClose();
    } catch (e) {
      toast((e as Error).message, true);
      setSending(false);
    }
  };

  const set = (patch: Partial<Settings>) => setSettings((s) => (s ? { ...s, ...patch } : s));

  return (
    <Modal onClose={onClose} wide>
      <div className="col" style={{ gap: 12, minWidth: 0 }}>
        <h2>Print {m.name}</h2>
        {files.length > 1 && (
          <label>
            What to print
            <select value={source} onChange={(e) => setSource(e.target.value)} disabled={!!task}>
              {files.map((f) => (
                <option key={f.id} value={`f${f.id}`}>
                  {f.rel_path} {isSliced(f) ? "(sliced)" : ""}
                </option>
              ))}
              {parts.length > 1 && <option value="all">All {parts.length} parts together</option>}
            </select>
          </label>
        )}
        <label>
          Printer
          <select value={machineId ?? ""} onChange={(e) => setMachineId(Number(e.target.value))} disabled={!!task}>
            {machines.data?.filter((x) => x.enabled).map((x) => (
              <option key={x.id} value={x.id}>
                {x.name} · {STATE_LABELS[x.needs_clear ? "needs_clear" : x.status.state]}
              </option>
            ))}
          </select>
        </label>
        {machine?.needs_clear && <p className="dim" style={{ margin: 0, color: "#d9822b" }}>The bed needs clearing. The print waits in the queue until someone confirms.</p>}

        {task ? (
          <p style={{ margin: 0 }}>
            {task.state === "failed" ? (
              <span style={{ color: "var(--danger)" }}>{task.error || "Slicing failed"}</span>
            ) : (
              <>
                {task.state === "queued" ? "Waiting to slice" : "Slicing…"} {task.ahead ? `(${task.ahead} ahead)` : ""}
              </>
            )}
          </p>
        ) : needsSlice ? (
          options.error ? (
            <p style={{ margin: 0, color: "#d9822b" }}>{(options.error as Error).message}</p>
          ) : settings && options.data ? (
            <div className="col" style={{ gap: 8 }}>
              <label>
                Quality
                <select value={settings.process} onChange={(e) => set({ process: e.target.value })}>
                  {options.data.processes.map((p) => <option key={p.name} value={p.name}>{p.name.split(" @")[0]}</option>)}
                </select>
              </label>
              {!!ams.length && (
                <label>
                  Filament slot
                  <select value={settings.slot} onChange={(e) => set({ slot: Number(e.target.value) })}>
                    <option value={-1}>External spool</option>
                    {ams.map((a) => <option key={a.unit * 4 + a.slot} value={a.unit * 4 + a.slot}>Slot {a.slot + 1} · {a.type}</option>)}
                  </select>
                </label>
              )}
              <label>
                Filament
                <select value={settings.filament} onChange={(e) => set({ filament: e.target.value })}>
                  {options.data.filaments.map((f) => <option key={f.name} value={f.name}>{f.name.split(" @")[0]}{f.user ? " (imported)" : ""}</option>)}
                </select>
              </label>
              <label>
                Build plate
                <select value={settings.bed} onChange={(e) => set({ bed: e.target.value })}>
                  {options.data.bed_types.map((b) => <option key={b}>{b}</option>)}
                </select>
              </label>
              <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
                <label>Layer height (mm)<input type="number" step={0.04} min={0.08} max={0.32} value={settings.layer_height} onChange={(e) => set({ layer_height: Number(e.target.value) })} /></label>
                <label>Infill (%)<input type="number" step={5} min={0} max={100} value={settings.infill} onChange={(e) => set({ infill: Number(e.target.value) })} /></label>
                <label>Walls<input type="number" min={1} max={8} value={settings.walls} onChange={(e) => set({ walls: Number(e.target.value) })} /></label>
                <label>Scale (%)<input type="number" step={5} min={10} max={400} value={settings.scale} onChange={(e) => set({ scale: Number(e.target.value) })} /></label>
              </div>
              <div className="row" style={{ gap: 12 }}>
                <label className="row" style={{ gap: 6 }}>
                  <input type="checkbox" checked={settings.supports} onChange={(e) => set({ supports: e.target.checked })} /> Supports
                </label>
                {settings.supports && (
                  <select value={settings.support_type} onChange={(e) => set({ support_type: e.target.value })}>
                    <option value="tree(auto)">Tree</option>
                    <option value="normal(auto)">Normal</option>
                  </select>
                )}
                <select value={settings.brim} onChange={(e) => set({ brim: e.target.value })}>
                  <option value="auto_brim">Brim: auto</option>
                  <option value="outer_only">Brim: outer only</option>
                  <option value="no_brim">No brim</option>
                </select>
              </div>
              <p className="faint" style={{ margin: 0, fontSize: 12 }}>Sliced on the server with OrcaSlicer using {options.data.printer}.</p>
              {window.innerWidth >= 700 && (
                <Link className="btn" style={{ alignSelf: "flex-start" }} to={`/models/${m.id}/prepare?machine=${machineId}&files=${source === "all" ? parts.map((f) => f.id).join(",") : fileId}`}>
                  Prepare in 3D…
                </Link>
              )}
            </div>
          ) : (
            <p className="dim">Loading slicer settings…</p>
          )
        ) : (
          i?.format && (
            <div className="col" style={{ gap: 8 }}>
              {i.plates.length > 1 && (
                <label>
                  Plate
                  <select value={plate} onChange={(e) => setPlate(Number(e.target.value))}>
                    {i.plates.map((p) => <option key={p.index} value={p.index}>Plate {p.index}{p.time_s ? ` · ${duration(p.time_s)}` : ""}</option>)}
                  </select>
                </label>
              )}
              <dl className="kv">
                <dt>Print time</dt>
                <dd>{duration(plateInfo?.time_s) ?? i.print_time ?? "Unknown"}</dd>
                <dt>Filament</dt>
                <dd>{plateInfo?.weight_g != null ? `${plateInfo.weight_g.toFixed(1)} g` : i.filament_g ? `${i.filament_g} g` : "Unknown"}</dd>
              </dl>
              {!!plateInfo?.filaments.length && !!ams.length && (
                <div className="col" style={{ gap: 6 }}>
                  <h3>Filament slots</h3>
                  {plateInfo.filaments.map((f) => (
                    <div key={f.id} className="row" style={{ gap: 8 }}>
                      <span style={{ width: 12, height: 12, flex: "none", borderRadius: 6, background: f.color, border: "1px solid var(--border)" }} />
                      <span className="grow" style={{ whiteSpace: "nowrap" }}>{f.type} · {f.used_g.toFixed(1)} g</span>
                      <select style={{ width: "auto", flex: "0 1 260px" }} value={mapping[f.id] ?? -1} onChange={(e) => setMapping({ ...mapping, [f.id]: Number(e.target.value) })}>
                        <option value={-1}>External spool</option>
                        {ams.map((a) => <option key={a.unit * 4 + a.slot} value={a.unit * 4 + a.slot}>AMS {a.unit + 1} · Slot {a.slot + 1} · {a.type}</option>)}
                      </select>
                    </div>
                  ))}
                </div>
              )}
              <button className="small" style={{ alignSelf: "flex-start" }} onClick={() => setPreview(!preview)}>
                {preview ? "Hide layer preview" : "Layer preview"}
              </button>
              {preview && printFile != null && <LayerPreview fileId={printFile} plate={plate} bed={machine?.bed ?? null} />}
            </div>
          )
        )}
        {i && i.format == null && !i.sliceable && source !== "all" && (
          <p style={{ margin: 0, color: "#d9822b" }}>This server can't slice files. Slice it in your slicer and add the G-code or sliced 3MF to the model.</p>
        )}
        <div className="row" style={{ gap: 8, justifyContent: "flex-end" }}>
          <button onClick={onClose}>Cancel</button>
          {needsSlice ? (
            <button className="primary" disabled={!settings || !!task || !!options.error} onClick={slice}>
              Slice
            </button>
          ) : (
            <button className="primary" disabled={printFile == null || !compatible || sending} onClick={send}>
              {willQueue ? "Queue" : "Print"}
            </button>
          )}
        </div>
      </div>
    </Modal>
  );
}

function colourDistance(a: string, b: string) {
  const rgb = (s: string) => {
    const v = parseInt(s.replace("#", "").slice(0, 6), 16);
    return Number.isNaN(v) ? [128, 128, 128] : [(v >> 16) & 255, (v >> 8) & 255, v & 255];
  };
  const x = rgb(a), y = rgb(b);
  return (x[0] - y[0]) ** 2 + (x[1] - y[1]) ** 2 + (x[2] - y[2]) ** 2;
}

/* ---------------------------------------------------------------- layer preview */

const FEATURE_COLORS = ["#f28c28", "#f2c94c", "#eb5757", "#9b51e0", "#e84393", "#5c6bc0", "#27ae60", "#2d9cdb", "#888"];

export function LayerPreview({ fileId, plate, bed }: { fileId: number; plate: number; bed: { x: number; y: number } | null }) {
  const summary = useQuery({ queryKey: ["toolpaths", fileId, plate], queryFn: () => api<ToolpathSummary>(`/files/${fileId}/toolpaths?plate=${plate}`) });
  const [index, setIndex] = useState(0);
  const layers = useRef(new Map<number, ToolpathLayer>());
  const [, redraw] = useState(0);
  const canvas = useRef<HTMLCanvasElement>(null);
  const s = summary.data;

  useEffect(() => {
    if (s) setIndex(Math.floor(s.layers / 2));
  }, [s]);
  useEffect(() => {
    for (const j of [index, index - 1]) {
      if (j < 0 || !s || j >= s.layers || layers.current.has(j)) continue;
      api<ToolpathLayer>(`/files/${fileId}/toolpaths/${j}?plate=${plate}`).then((l) => {
        layers.current.set(j, l);
        redraw((n) => n + 1);
      });
    }
  });
  useEffect(() => {
    const c = canvas.current;
    if (!c || !s) return;
    const ctx = c.getContext("2d")!;
    const size = c.width;
    ctx.clearRect(0, 0, size, size);
    const b = s.bounds ?? [0, 0, 1, 1];
    const [minX, minY, maxX, maxY] = bed ? [0, 0, bed.x, bed.y] : [b[0] - 5, b[1] - 5, b[2] + 5, b[3] + 5];
    const k = size / Math.max(maxX - minX, maxY - minY, 1);
    const px = (x: number) => (x - minX) * k;
    const py = (y: number) => size - (y - minY) * k;
    if (bed) {
      ctx.strokeStyle = "rgba(128,128,128,0.5)";
      ctx.strokeRect(px(minX), py(maxY), (maxX - minX) * k, (maxY - minY) * k);
    }
    ctx.lineWidth = Math.max(0.4 * k, 0.6);
    ctx.lineCap = "round";
    const draw = (l: ToolpathLayer | undefined, colour?: string) => {
      for (const p of l?.paths ?? []) {
        ctx.strokeStyle = colour ?? FEATURE_COLORS[Math.min(p.f, FEATURE_COLORS.length - 1)];
        ctx.beginPath();
        ctx.moveTo(px(p.p[0]), py(p.p[1]));
        for (let j = 2; j + 1 < p.p.length; j += 2) ctx.lineTo(px(p.p[j]), py(p.p[j + 1]));
        ctx.stroke();
      }
    };
    draw(layers.current.get(index - 1), "rgba(128,128,128,0.25)");
    draw(layers.current.get(index));
  });

  if (summary.error) return <p className="dim">{(summary.error as Error).message}</p>;
  if (!s) return <p className="dim">Loading toolpaths…</p>;
  return (
    <div className="col" style={{ gap: 6 }}>
      <canvas ref={canvas} width={480} height={480} style={{ width: "100%", maxWidth: 480, aspectRatio: "1", background: "var(--bg-sunken)", borderRadius: 8 }} />
      <div className="row dim" style={{ fontSize: 13 }}>
        <span>Layer {index + 1} of {s.layers}</span>
        <span className="spacer" />
        <span>{(s.z[index] ?? 0).toFixed(2)} mm</span>
      </div>
      <input type="range" min={0} max={Math.max(0, s.layers - 1)} value={index} onChange={(e) => setIndex(Number(e.target.value))} />
    </div>
  );
}
