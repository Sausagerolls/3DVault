import { useEffect, useMemo, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useNavigate, Link } from "react-router-dom";
import { api, formatBytes, uploadForm, type Batch, type StagedFile } from "../api";
import { CategorySelect, Icon, TagInput, useToast } from "../components/ui";
import { collectDropped, fromInput, type DroppedFile } from "./drop";

let pendingDrop: DroppedFile[] | null = null;
/** Lets the global drop handler hand files to this page before it mounts. */
export function setPendingDrop(files: DroppedFile[]) {
  pendingDrop = files;
}

type Group = { key: string; name: string; file_ids: string[]; category_id: number | null; tags: string[]; source_url: string; skip_duplicates: boolean };

const CHUNK_BYTES = 256 * 1024 * 1024;
const CHUNK_FILES = 40;
let groupSeq = 0;

export default function Upload() {
  const qc = useQueryClient();
  const navigate = useNavigate();
  const toast = useToast();
  const [batchId, setBatchId] = useState<string | null>(null);
  const [files, setFiles] = useState<StagedFile[]>([]);
  const [groups, setGroups] = useState<Group[]>([]);
  const [progress, setProgress] = useState<{ done: number; total: number } | null>(null);
  const [over, setOver] = useState(false);
  const [committing, setCommitting] = useState(false);
  const [allCat, setAllCat] = useState<number | null>(null);
  const [allTags, setAllTags] = useState<string[]>([]);
  const [dragFile, setDragFile] = useState<string | null>(null);
  const fileInput = useRef<HTMLInputElement>(null);
  const folderInput = useRef<HTMLInputElement>(null);
  const byId = useMemo(() => new Map(files.map((f) => [f.id, f])), [files]);

  const ingest = async (dropped: DroppedFile[]) => {
    if (!dropped.length) return;
    let id = batchId;
    if (!id) {
      id = (await api<Batch>("/uploads", { method: "POST" })).id;
      setBatchId(id);
    }
    const total = dropped.reduce((n, d) => n + d.file.size, 0);
    let done = 0;
    setProgress({ done: 0, total });
    let latest: Batch | null = null;
    try {
      // Send in chunks so one huge drop does not become one giant request.
      for (let i = 0; i < dropped.length; ) {
        const form = new FormData();
        let bytes = 0;
        let n = 0;
        while (i < dropped.length && n < CHUNK_FILES && (n === 0 || bytes + dropped[i].file.size < CHUNK_BYTES)) {
          form.append("files", dropped[i].file, dropped[i].file.name);
          form.append("paths", dropped[i].path);
          bytes += dropped[i].file.size;
          n++;
          i++;
        }
        const base = done;
        latest = await uploadForm<Batch>(`/uploads/${id}/files`, form, (f) => setProgress({ done: base + f * bytes, total }));
        done += bytes;
      }
    } catch (e) {
      toast(`Upload failed: ${(e as Error).message}`, true);
    }
    setProgress(null);
    if (latest) {
      setFiles(latest.files);
      // Keep edits to groups that already exist; add proposals for new files only.
      setGroups((prev) => {
        const known = new Set(prev.flatMap((g) => g.file_ids));
        const fresh = latest!.groups
          .map((g) => ({ ...g, file_ids: g.file_ids.filter((f) => !known.has(f)) }))
          .filter((g) => g.file_ids.length)
          .map((g) => ({ key: `g${++groupSeq}`, name: g.name, file_ids: g.file_ids, category_id: null, tags: [], source_url: "", skip_duplicates: true }));
        return [...prev, ...fresh];
      });
    }
  };

  useEffect(() => {
    if (pendingDrop) {
      const d = pendingDrop;
      pendingDrop = null;
      ingest(d);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const update = (key: string, patch: Partial<Group>) => setGroups((gs) => gs.map((g) => (g.key === key ? { ...g, ...patch } : g)));
  const moveFile = (fileId: string, toKey: string | "new") =>
    setGroups((gs) => {
      const from = gs.find((g) => g.file_ids.includes(fileId));
      let next = gs.map((g) => ({ ...g, file_ids: g.file_ids.filter((f) => f !== fileId) }));
      if (toKey === "new") {
        const f = byId.get(fileId);
        const name = f ? f.path.split("/").pop()!.replace(/\.[^.]+$/, "").replace(/[_-]+/g, " ") : "New model";
        next.push({ key: `g${++groupSeq}`, name, file_ids: [fileId], category_id: from?.category_id ?? null, tags: from?.tags ?? [], source_url: "", skip_duplicates: true });
      } else next = next.map((g) => (g.key === toKey ? { ...g, file_ids: [...g.file_ids, fileId] } : g));
      return next.filter((g) => g.file_ids.length);
    });
  const mergeInto = (key: string, intoKey: string) =>
    setGroups((gs) => {
      const src = gs.find((g) => g.key === key)!;
      return gs.filter((g) => g.key !== key).map((g) => (g.key === intoKey ? { ...g, file_ids: [...g.file_ids, ...src.file_ids] } : g));
    });

  const applyAll = () =>
    setGroups((gs) => gs.map((g) => ({ ...g, category_id: allCat ?? g.category_id, tags: Array.from(new Set([...g.tags, ...allTags])) })));

  const commit = async () => {
    if (!batchId) return;
    setCommitting(true);
    try {
      const body = { groups: groups.map(({ key: _k, ...g }) => g) };
      const r = await api<{ model_ids: number[] }>(`/uploads/${batchId}/commit`, { method: "POST", json: body });
      toast(`Added ${r.model_ids.length} model${r.model_ids.length === 1 ? "" : "s"}`);
      qc.invalidateQueries();
      const anyUntriaged = groups.some((g) => !g.category_id);
      navigate(r.model_ids.length === 1 ? `/models/${r.model_ids[0]}` : anyUntriaged ? "/untriaged" : "/");
    } catch (e) {
      toast((e as Error).message, true);
      setCommitting(false);
    }
  };

  const discard = async () => {
    if (batchId) await api(`/uploads/${batchId}`, { method: "DELETE" });
    setBatchId(null);
    setFiles([]);
    setGroups([]);
  };

  const dupCount = files.filter((f) => f.dup_model_id).length;

  return (
    <div className="page">
      <div className="page narrow col" style={{ padding: 0, gap: 18 }}>
        <div className="row">
          <h1>Upload</h1>
          <span className="spacer" />
          {groups.length > 0 && (
            <>
              <button onClick={discard} disabled={committing}>
                Discard
              </button>
              <button className="primary" onClick={commit} disabled={committing || !!progress}>
                Add {groups.length} model{groups.length === 1 ? "" : "s"}
              </button>
            </>
          )}
        </div>

        <div
          className={`dropzone ${over ? "over" : ""}`}
          onDragOver={(e) => (e.preventDefault(), setOver(true))}
          onDragLeave={() => setOver(false)}
          onDrop={async (e) => {
            e.preventDefault();
            e.stopPropagation();
            setOver(false);
            ingest(await collectDropped(e.dataTransfer));
          }}
        >
          <Icon name="upload" size={32} />
          <p style={{ margin: "10px 0 4px", fontSize: 16, color: "var(--text)" }}>Drop files, folders or zips here</p>
          <p className="faint" style={{ margin: "0 0 14px", fontSize: 13 }}>
            STL, 3MF, OBJ, PLY, STEP, G-code, images. Zips become one model each, folders become one model per subfolder. You review before anything is saved.
          </p>
          <div className="row" style={{ justifyContent: "center" }}>
            <button onClick={() => fileInput.current?.click()}>Choose files</button>
            <button onClick={() => folderInput.current?.click()}>Choose folder</button>
          </div>
          <input ref={fileInput} type="file" multiple hidden onChange={(e) => (ingest(fromInput(e.target.files)), (e.target.value = ""))} />
          <input
            ref={folderInput}
            type="file"
            hidden
            // @ts-expect-error non-standard but supported in all modern browsers
            webkitdirectory=""
            onChange={(e) => (ingest(fromInput(e.target.files)), (e.target.value = ""))}
          />
          {progress && (
            <div style={{ maxWidth: 400, margin: "16px auto 0" }}>
              <div className="progress">
                <div style={{ width: `${(progress.done / Math.max(progress.total, 1)) * 100}%` }} />
              </div>
              <p className="faint" style={{ fontSize: 12 }}>
                Uploading {formatBytes(progress.done)} of {formatBytes(progress.total)}
              </p>
            </div>
          )}
        </div>

        {groups.length > 0 && (
          <div className="panel row wrap" style={{ gap: 12 }}>
            <strong>Apply to all</strong>
            <div style={{ width: 220 }}>
              <CategorySelect value={allCat} onChange={setAllCat} noneLabel="Category…" />
            </div>
            <div className="grow" style={{ minWidth: 220 }}>
              <TagInput value={allTags} onChange={setAllTags} />
            </div>
            <button onClick={applyAll} disabled={!allCat && !allTags.length}>
              Apply
            </button>
            {dupCount > 0 && (
              <span className="chip danger" title="These files already exist in the library">
                {dupCount} duplicate file{dupCount === 1 ? "" : "s"}
              </span>
            )}
          </div>
        )}

        {groups.length > 0 && (
          <p className="faint" style={{ margin: 0, fontSize: 13 }}>
            Drag files between models to regroup. Models without a category go to <Link to="/untriaged" className="link">Untriaged</Link>.
          </p>
        )}

        <div className="col" style={{ gap: 12 }}>
          {groups.map((g) => {
            const dups = g.file_ids.filter((id) => byId.get(id)?.dup_model_id);
            const size = g.file_ids.reduce((n, id) => n + (byId.get(id)?.size ?? 0), 0);
            return (
              <div
                key={g.key}
                className={`card group-card ${dragFile && !g.file_ids.includes(dragFile) ? "" : ""}`}
                onDragOver={(e) => dragFile && e.preventDefault()}
                onDrop={(e) => {
                  e.preventDefault();
                  if (dragFile) moveFile(dragFile, g.key);
                  setDragFile(null);
                }}
              >
                <div className="row wrap">
                  <input className="grow" style={{ fontWeight: 600, minWidth: 200, flex: 2 }} value={g.name} onChange={(e) => update(g.key, { name: e.target.value })} />
                  <div style={{ width: 200 }}>
                    <CategorySelect value={g.category_id} onChange={(category_id) => update(g.key, { category_id })} noneLabel="Untriaged" />
                  </div>
                  <select
                    style={{ width: 130 }}
                    value=""
                    onChange={(e) => e.target.value && mergeInto(g.key, e.target.value)}
                    title="Merge this model into another"
                  >
                    <option value="">Merge into…</option>
                    {groups
                      .filter((o) => o.key !== g.key)
                      .map((o) => (
                        <option key={o.key} value={o.key}>
                          {o.name}
                        </option>
                      ))}
                  </select>
                  <button className="ghost icon" title="Remove from upload" onClick={() => setGroups((gs) => gs.filter((x) => x.key !== g.key))}>
                    <Icon name="close" />
                  </button>
                </div>
                <div className="row wrap">
                  <div className="grow" style={{ minWidth: 220 }}>
                    <TagInput value={g.tags} onChange={(tags) => update(g.key, { tags })} />
                  </div>
                  <input
                    style={{ flex: 1, minWidth: 220 }}
                    placeholder="Source link (optional, imports details)"
                    value={g.source_url}
                    onChange={(e) => update(g.key, { source_url: e.target.value })}
                  />
                </div>
                <div className="group-files">
                  {g.file_ids.map((id) => {
                    const f = byId.get(id);
                    if (!f) return null;
                    return (
                      <div key={id} className="gf" draggable onDragStart={() => setDragFile(id)} onDragEnd={() => setDragFile(null)}>
                        <span className="chip" style={{ width: 54, justifyContent: "center" }}>
                          {f.path.split(".").pop()?.toLowerCase()}
                        </span>
                        <span className="grow ellipsis">{f.path}</span>
                        {f.dup_model_id && (
                          <Link to={`/models/${f.dup_model_id}`} target="_blank" className="chip danger" title="Identical file already in library">
                            duplicate
                          </Link>
                        )}
                        <span className="faint" style={{ fontSize: 12 }}>
                          {formatBytes(f.size)}
                        </span>
                        {g.file_ids.length > 1 && (
                          <button className="small ghost" onClick={() => moveFile(id, "new")} title="Split into its own model">
                            Split
                          </button>
                        )}
                      </div>
                    );
                  })}
                </div>
                <div className="row faint" style={{ fontSize: 12 }}>
                  {g.file_ids.length} file{g.file_ids.length === 1 ? "" : "s"} · {formatBytes(size)}
                  {dups.length > 0 && (
                    <label className="check" style={{ marginLeft: "auto" }}>
                      <input type="checkbox" checked={g.skip_duplicates} onChange={(e) => update(g.key, { skip_duplicates: e.target.checked })} />
                      Skip {dups.length} duplicate{dups.length === 1 ? "" : "s"}
                    </label>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
