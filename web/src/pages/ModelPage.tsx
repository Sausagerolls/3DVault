import { useEffect, useMemo, useRef, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useNavigate, useParams } from "react-router-dom";
import {
  FLAG_LABELS,
  STATUS_LABELS,
  api,
  downloadUrl,
  formatBytes,
  formatDims,
  modelZipUrl,
  thumbUrl,
  uploadForm,
  type Collection,
  type FlagKind,
  type ModelDetail,
  type MyState,
  type Printer,
  type Status,
  type User,
  type VaultFile,
} from "../api";
import { ModelViewer } from "../components/ModelViewer";
import { CategorySelect, Icon, Stars, TagInput, useToast } from "../components/ui";
import { useUser } from "../App";

export default function ModelPage() {
  const { id } = useParams();
  const qc = useQueryClient();
  const navigate = useNavigate();
  const toast = useToast();
  const user = useUser();
  const key = ["model", id];
  const q = useQuery({
    queryKey: key,
    queryFn: () => api<ModelDetail>(`/models/${id}`),
    refetchInterval: (query) => (query.state.data?.files.some((f) => f.status === "pending") ? 3000 : false),
  });
  const printers = useQuery({ queryKey: ["printers"], queryFn: () => api<Printer[]>("/printers") });
  const users = useQuery({ queryKey: ["users"], queryFn: () => api<User[]>("/users") });
  const collections = useQuery({ queryKey: ["collections"], queryFn: () => api<Collection[]>("/collections") });
  const m = q.data;
  const [activeId, setActiveId] = useState<number | null>(null);
  const [editing, setEditing] = useState(false);

  const visualFiles = useMemo(() => (m ? m.files.filter((f) => f.has_preview || f.has_thumb) : []), [m]);
  const active: VaultFile | null = useMemo(() => {
    if (!m) return null;
    const pick = m.files.find((f) => f.id === activeId);
    return pick ?? m.files.find((f) => f.has_preview && f.id === m.preview_file_id) ?? m.files.find((f) => f.has_preview) ?? visualFiles[0] ?? null;
  }, [m, activeId, visualFiles]);

  useEffect(() => setActiveId(null), [id]);

  if (q.isLoading) return <div className="page" />;
  if (q.error || !m) return <div className="page"><div className="error-box">{(q.error as Error)?.message ?? "Not found"}</div></div>;

  const refresh = () => {
    qc.invalidateQueries({ queryKey: key });
    qc.invalidateQueries({ queryKey: ["models"] });
    qc.invalidateQueries({ queryKey: ["stats"] });
  };

  const patch = async (body: Record<string, unknown>) => {
    try {
      const out = await api<ModelDetail>(`/models/${m.id}`, { method: "PATCH", json: body });
      qc.setQueryData(key, out);
      qc.invalidateQueries({ queryKey: ["models"] });
      qc.invalidateQueries({ queryKey: ["tags"] });
      qc.invalidateQueries({ queryKey: ["categories"] });
      qc.invalidateQueries({ queryKey: ["stats"] });
    } catch (e) {
      toast((e as Error).message, true);
    }
  };

  const setMe = async (body: Partial<{ favourite: boolean; rating: number; status: Status | "" }>) => {
    const me = await api<MyState>(`/models/${m.id}/me`, { method: "PUT", json: body });
    qc.setQueryData(key, { ...m, me });
    qc.invalidateQueries({ queryKey: ["models"] });
  };

  const canDelete = user.role === "admin" || m.uploader?.id === user.id;
  const openFlags = m.flags.filter((f) => !f.resolved);
  const meshFiles = m.files.filter((f) => f.kind === "mesh" || f.kind === "cad");
  const otherFiles = m.files.filter((f) => f.kind !== "mesh" && f.kind !== "cad");
  const userName = (uid: number | null) => users.data?.find((u) => u.id === uid)?.display_name ?? "someone";

  return (
    <div className="model-page">
      <div className="col" style={{ gap: 0, minWidth: 0 }}>
        <ModelViewer file={active} />
        {visualFiles.length > 1 && (
          <div className="filmstrip">
            {visualFiles.map((f) => (
              <button key={f.id} className={active?.id === f.id ? "active" : ""} onClick={() => setActiveId(f.id)} title={f.rel_path}>
                <img src={thumbUrl(f.id)} alt="" loading="lazy" />
              </button>
            ))}
          </div>
        )}

        <section className="panel" style={{ marginTop: 16 }}>
          <div className="row" style={{ marginBottom: 8 }}>
            <h2>Files</h2>
            <span className="faint">{m.files.length}</span>
            <span className="spacer" />
            <AddFiles modelId={m.id} onDone={refresh} />
            <a className="btn primary" href={modelZipUrl(m.id)}>
              <Icon name="download" /> Download all
            </a>
          </div>
          <div className="filelist">
            {[...meshFiles, ...otherFiles].map((f) => (
              <FileRow
                key={f.id}
                f={f}
                isCover={m.cover_file_id === f.id}
                onShow={() => setActiveId(f.id)}
                onCover={() => patch({ cover_file_id: f.id })}
                onDelete={
                  canDelete
                    ? async () => {
                        if (!window.confirm(`Delete ${f.rel_path}? This cannot be undone.`)) return;
                        await api(`/files/${f.id}`, { method: "DELETE" });
                        refresh();
                      }
                    : undefined
                }
                onReprocess={async () => {
                  await api(`/files/${f.id}/reprocess`, { method: "POST" });
                  refresh();
                }}
              />
            ))}
          </div>
        </section>

        <section className="panel" style={{ marginTop: 16 }}>
          <div className="row" style={{ marginBottom: 8 }}>
            <h2>Print photos</h2>
            <span className="spacer" />
            <AddFiles modelId={m.id} onDone={refresh} photo />
          </div>
          {m.files.some((f) => f.kind === "photo") ? (
            <div className="filmstrip">
              {m.files
                .filter((f) => f.kind === "photo")
                .map((f) => (
                  <button key={f.id} onClick={() => setActiveId(f.id)} style={{ width: 120, height: 120 }}>
                    {f.has_thumb ? <img src={thumbUrl(f.id)} alt="" style={{ objectFit: "cover" }} /> : "…"}
                  </button>
                ))}
            </div>
          ) : (
            <p className="faint" style={{ margin: 0 }}>Add photos of your prints. The first photo becomes the cover.</p>
          )}
        </section>
      </div>

      <div className="side-col">
        <div className="col" style={{ gap: 6 }}>
          {m.deleted_at && (
            <div className="error-box row">
              In trash
              <span className="spacer" />
              <button
                className="small"
                onClick={async () => {
                  await api(`/models/${m.id}/restore`, { method: "POST" });
                  refresh();
                }}
              >
                Restore
              </button>
            </div>
          )}
          {m.category_path.length > 0 && (
            <div className="faint" style={{ fontSize: 12 }}>
              {m.category_path.join(" › ")}
            </div>
          )}
          <div className="row" style={{ alignItems: "flex-start" }}>
            <h1 className="grow" style={{ overflowWrap: "anywhere" }}>
              {m.name}
            </h1>
            <button className={`icon ${m.me.favourite ? "active" : ""}`} onClick={() => setMe({ favourite: !m.me.favourite })} title="Favourite">
              <Icon name="heart" className={m.me.favourite ? "fav" : ""} />
            </button>
          </div>
          {m.untriaged && !m.deleted_at && (
            <div className="row" style={{ background: "var(--accent-soft)", padding: "8px 12px", borderRadius: 8 }}>
              <span className="grow" style={{ color: "var(--accent)" }}>New: pick a category to file it.</span>
              <button className="small" onClick={() => patch({ untriaged: false })}>
                Mark triaged
              </button>
            </div>
          )}
        </div>

        <section className="panel col">
          <h3>My print status</h3>
          <div className="status-seg">
            {(Object.keys(STATUS_LABELS) as Status[]).map((s) => (
              <button key={s} className={`small ${m.me.status === s ? "active" : ""}`} onClick={() => setMe({ status: m.me.status === s ? "" : s })}>
                {STATUS_LABELS[s]}
              </button>
            ))}
          </div>
          <div className="row">
            <span className="dim">My rating</span>
            <Stars value={m.me.rating} onChange={(rating) => setMe({ rating })} />
          </div>
        </section>

        {editing ? (
          <EditForm m={m} printers={printers.data ?? []} onCancel={() => setEditing(false)} onSave={async (b) => (await patch(b), setEditing(false))} />
        ) : (
          <section className="panel col">
            <div className="row">
              <h3>Details</h3>
              <span className="spacer" />
              <button className="small" onClick={() => setEditing(true)}>
                Edit
              </button>
            </div>
            <div className="row" style={{ gap: 8 }}>
              <div className="grow">
                <CategorySelect value={m.category_id} onChange={(cid) => patch(cid ? { category_id: cid } : { clear_category: true })} />
              </div>
            </div>
            <TagInput value={m.tags} onChange={(tags) => patch({ tags })} />
            <dl className="kv">
              {m.source_url && (
                <>
                  <dt>Source</dt>
                  <dd>
                    <a className="link" href={m.source_url} target="_blank" rel="noreferrer">
                      {hostOf(m.source_url)} <Icon name="external" size={11} />
                    </a>
                  </dd>
                </>
              )}
              {m.author && (
                <>
                  <dt>Author</dt>
                  <dd>{m.author}</dd>
                </>
              )}
              {m.license && (
                <>
                  <dt>License</dt>
                  <dd>{m.license}</dd>
                </>
              )}
              <dt>Largest part</dt>
              <dd>{formatDims(m.size_x, m.size_y, m.size_z) || "—"}</dd>
              <dt>Parts</dt>
              <dd>
                {m.part_count} {m.tri_count ? <span className="faint">· {m.tri_count.toLocaleString()} triangles</span> : null}
              </dd>
              <dt>Fits</dt>
              <dd>{fitsList(m, printers.data ?? []) || "—"}</dd>
              {m.printer_ids.length > 0 && (
                <>
                  <dt>For printers</dt>
                  <dd>{printers.data?.filter((p) => m.printer_ids.includes(p.id)).map((p) => p.name).join(", ")}</dd>
                </>
              )}
              <dt>Added</dt>
              <dd>
                {new Date(m.created_at).toLocaleDateString()} {m.uploader && <span className="faint">by {m.uploader.display_name}</span>}
              </dd>
            </dl>
            {m.description && <div className="prose">{m.description}</div>}
          </section>
        )}

        <section className="panel col">
          <h3>Print notes</h3>
          <NotesEditor value={m.print_notes} onSave={(print_notes) => patch({ print_notes })} />
        </section>

        <UrlImport m={m} onDone={(out) => (qc.setQueryData(key, out), refresh())} />

        <section className="panel col">
          <div className="row">
            <h3>Problems</h3>
            <span className="spacer" />
            <FlagButton modelId={m.id} onDone={refresh} />
          </div>
          {m.flags.length === 0 && <span className="faint">No problems reported.</span>}
          {m.flags.map((f) => (
            <div key={f.id} className="row" style={{ opacity: f.resolved ? 0.5 : 1 }}>
              <span className={`chip ${f.resolved ? "" : "danger"}`}>{FLAG_LABELS[f.kind]}</span>
              <span className="grow dim ellipsis" title={f.note}>
                {f.note} <span className="faint">— {userName(f.user_id)}</span>
              </span>
              <button
                className="small ghost"
                onClick={async () => {
                  await api(`/flags/${f.id}?resolved=${!f.resolved}`, { method: "PATCH" });
                  refresh();
                }}
              >
                {f.resolved ? "Reopen" : "Resolve"}
              </button>
            </div>
          ))}
          {openFlags.length > 0 && <span className="faint" style={{ fontSize: 12 }}>Flags are shared with everyone.</span>}
        </section>

        {!!collections.data?.length && (
          <section className="panel col">
            <h3>Collections</h3>
            <div className="row wrap">
              {collections.data
                .filter((c) => c.kind === "manual")
                .map((c) => {
                  const inIt = m.collection_ids.includes(c.id);
                  return (
                    <button
                      key={c.id}
                      className={`small ${inIt ? "active" : ""}`}
                      onClick={async () => {
                        await api("/models/bulk", { method: "POST", json: { ids: [m.id], [inIt ? "remove_from_collection" : "add_to_collection"]: c.id } });
                        refresh();
                        qc.invalidateQueries({ queryKey: ["collections"] });
                      }}
                    >
                      {inIt && <Icon name="check" size={12} />} {c.name}
                    </button>
                  );
                })}
            </div>
          </section>
        )}

        {canDelete && !m.deleted_at && (
          <button
            className="danger"
            onClick={async () => {
              await api(`/models/${m.id}`, { method: "DELETE" });
              toast(`Moved “${m.name}” to trash`);
              refresh();
              navigate(-1);
            }}
          >
            <Icon name="trash" /> Move to trash
          </button>
        )}
        <Link to="/" className="faint" style={{ fontSize: 12 }}>
          ← Back to library
        </Link>
      </div>
    </div>
  );
}

function hostOf(url: string) {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return url;
  }
}

function fitsList(m: ModelDetail, printers: Printer[]) {
  if (m.size_x == null) return "";
  // Uses the largest part as a quick indicator. Library filter checks every part.
  const dims = [m.size_x, m.size_y!, m.size_z!].sort((a, b) => b - a);
  return printers
    .filter((p) => {
      const bed = [p.x, p.y, p.z].sort((a, b) => b - a);
      return dims.every((d, i) => d <= bed[i]);
    })
    .map((p) => p.name)
    .join(", ");
}

function FileRow({
  f,
  isCover,
  onShow,
  onCover,
  onDelete,
  onReprocess,
}: {
  f: VaultFile;
  isCover: boolean;
  onShow: () => void;
  onCover: () => void;
  onDelete?: () => void;
  onReprocess: () => void;
}) {
  const meta = Object.entries(f.meta).filter(([k]) => ["print_time", "filament_g", "filament_type", "layer_height", "slicer", "printer_model"].includes(k));
  return (
    <div className="frow">
      {f.has_thumb ? <img src={thumbUrl(f.id)} alt="" loading="lazy" /> : <span className="ext">{f.ext}</span>}
      <div className="grow" style={{ minWidth: 0, cursor: f.has_thumb ? "pointer" : "default" }} onClick={f.has_thumb ? onShow : undefined}>
        <div className="ellipsis" title={f.rel_path}>
          {f.rel_path}
        </div>
        <div className="faint row wrap" style={{ fontSize: 12, gap: 6 }}>
          <span>{formatBytes(f.size)}</span>
          {f.size_x != null && <span>{formatDims(f.size_x, f.size_y, f.size_z)}</span>}
          {f.meta.slicer_project && <span className="chip">slicer project</span>}
          {meta.map(([k, v]) => (
            <span key={k}>{k === "filament_g" ? `${v} g` : String(v)}</span>
          ))}
          {f.status === "pending" && <span className="chip">processing…</span>}
          {f.status === "error" && (
            <span className="chip danger" title={f.error}>
              error
            </span>
          )}
          {isCover && <span className="chip accent">cover</span>}
        </div>
      </div>
      {f.has_thumb && !isCover && (
        <button className="small ghost" onClick={onCover} title="Use as cover">
          Cover
        </button>
      )}
      {f.status === "error" && (
        <button className="small ghost" onClick={onReprocess} title="Retry processing">
          <Icon name="refresh" size={13} />
        </button>
      )}
      <a className="btn small" href={downloadUrl(f.id)} title="Download">
        <Icon name="download" size={14} />
      </a>
      {onDelete && (
        <button className="small ghost danger" onClick={onDelete} title="Delete file">
          <Icon name="trash" size={13} />
        </button>
      )}
    </div>
  );
}

function AddFiles({ modelId, onDone, photo = false }: { modelId: number; onDone: () => void; photo?: boolean }) {
  const input = useRef<HTMLInputElement>(null);
  const toast = useToast();
  const [progress, setProgress] = useState<number | null>(null);
  const send = async (files: FileList | null) => {
    if (!files?.length) return;
    const form = new FormData();
    Array.from(files).forEach((f) => form.append("files", f));
    if (photo) form.append("photo", "true");
    setProgress(0);
    try {
      await uploadForm(`/models/${modelId}/files`, form, setProgress);
      onDone();
    } catch (e) {
      toast((e as Error).message, true);
    } finally {
      setProgress(null);
      if (input.current) input.current.value = "";
    }
  };
  return (
    <>
      <input ref={input} type="file" multiple hidden accept={photo ? "image/*" : undefined} onChange={(e) => send(e.target.files)} />
      <button className="small" onClick={() => input.current?.click()} disabled={progress !== null}>
        {progress !== null ? `${Math.round(progress * 100)}%` : photo ? "+ Photo" : "+ Add files"}
      </button>
    </>
  );
}

function NotesEditor({ value, onSave }: { value: string; onSave: (v: string) => void }) {
  const [text, setText] = useState(value);
  useEffect(() => setText(value), [value]);
  return (
    <>
      <textarea
        value={text}
        placeholder="Material, layer height, infill, supports, what worked…"
        onChange={(e) => setText(e.target.value)}
        onBlur={() => text !== value && onSave(text)}
      />
    </>
  );
}

function EditForm({
  m,
  printers,
  onSave,
  onCancel,
}: {
  m: ModelDetail;
  printers: Printer[];
  onSave: (b: Record<string, unknown>) => void;
  onCancel: () => void;
}) {
  const [f, setF] = useState({
    name: m.name,
    description: m.description,
    source_url: m.source_url,
    author: m.author,
    license: m.license,
    printer_ids: m.printer_ids,
  });
  const upd = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => setF({ ...f, [k]: e.target.value });
  return (
    <section className="panel col">
      <h3>Edit details</h3>
      <label className="field">
        Name
        <input value={f.name} onChange={upd("name")} />
      </label>
      <label className="field">
        Description
        <textarea value={f.description} onChange={upd("description")} rows={6} />
      </label>
      <label className="field">
        Source URL
        <input value={f.source_url} onChange={upd("source_url")} placeholder="https://www.printables.com/model/…" />
      </label>
      <div className="row">
        <label className="field grow">
          Author
          <input value={f.author} onChange={upd("author")} />
        </label>
        <label className="field grow">
          License
          <input value={f.license} onChange={upd("license")} list="licenses" />
          <datalist id="licenses">
            {["CC BY", "CC BY-SA", "CC BY-NC", "CC BY-NC-SA", "CC BY-ND", "CC BY-NC-ND", "CC0", "GPL", "MIT", "Standard Digital File License", "Personal use"].map((l) => (
              <option key={l} value={l} />
            ))}
          </datalist>
        </label>
      </div>
      <div className="field">
        Made for printers
        <div className="row wrap">
          {printers.map((p) => (
            <label key={p.id} className="check">
              <input
                type="checkbox"
                checked={f.printer_ids.includes(p.id)}
                onChange={(e) => setF({ ...f, printer_ids: e.target.checked ? [...f.printer_ids, p.id] : f.printer_ids.filter((x) => x !== p.id) })}
              />
              {p.name}
            </label>
          ))}
        </div>
      </div>
      <div className="row">
        <span className="spacer" />
        <button onClick={onCancel}>Cancel</button>
        <button className="primary" onClick={() => onSave(f)}>
          Save
        </button>
      </div>
    </section>
  );
}

function UrlImport({ m, onDone }: { m: ModelDetail; onDone: (m: ModelDetail) => void }) {
  const toast = useToast();
  const [url, setUrl] = useState(m.source_url);
  const [busy, setBusy] = useState(false);
  const [overwrite, setOverwrite] = useState(false);
  useEffect(() => setUrl(m.source_url), [m.source_url]);
  const go = async () => {
    setBusy(true);
    try {
      const out = await api<ModelDetail>(`/models/${m.id}/import-url?url=${encodeURIComponent(url)}&overwrite=${overwrite}`, { method: "POST" });
      onDone(out);
      toast("Imported details from link");
    } catch (e) {
      toast((e as Error).message, true);
    } finally {
      setBusy(false);
    }
  };
  return (
    <section className="panel col">
      <h3>Import details from link</h3>
      <div className="row">
        <input placeholder="Printables, Thingiverse or MakerWorld URL" value={url} onChange={(e) => setUrl(e.target.value)} />
        <button onClick={go} disabled={!url || busy}>
          <Icon name="link" /> {busy ? "…" : "Import"}
        </button>
      </div>
      <label className="check faint" style={{ fontSize: 12 }}>
        <input type="checkbox" checked={overwrite} onChange={(e) => setOverwrite(e.target.checked)} /> Overwrite fields I already filled in
      </label>
    </section>
  );
}

function FlagButton({ modelId, onDone }: { modelId: number; onDone: () => void }) {
  const [open, setOpen] = useState(false);
  const [kind, setKind] = useState<FlagKind>("broken_mesh");
  const [note, setNote] = useState("");
  return (
    <div className="rel">
      <button className="small" onClick={() => setOpen(!open)}>
        <Icon name="flag" size={13} /> Flag
      </button>
      {open && (
        <div className="popover down" style={{ right: 0, left: "auto" }}>
          <select value={kind} onChange={(e) => setKind(e.target.value as FlagKind)}>
            {(Object.keys(FLAG_LABELS) as FlagKind[]).map((k) => (
              <option key={k} value={k}>
                {FLAG_LABELS[k]}
              </option>
            ))}
          </select>
          <input placeholder="What's wrong?" value={note} onChange={(e) => setNote(e.target.value)} />
          <button
            className="primary"
            onClick={async () => {
              await api(`/models/${modelId}/flags`, { method: "POST", json: { kind, note } });
              setOpen(false);
              setNote("");
              onDone();
            }}
          >
            Add flag
          </button>
        </div>
      )}
    </div>
  );
}
