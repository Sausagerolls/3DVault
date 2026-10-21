import { useCallback, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { FLAG_LABELS, STATUS_LABELS, api, type Collection, type FlagKind } from "../api";
import { CategorySelect, Icon, TagInput, useOutsideClose, useToast } from "./ui";

type Props = { ids: number[]; trashed: boolean; onClear: () => void };

type Pop = null | "category" | "tags" | "status" | "flag" | "collection";

export function BulkBar({ ids, trashed, onClear }: Props) {
  const qc = useQueryClient();
  const toast = useToast();
  const [pop, setPop] = useState<Pop>(null);
  const close = useCallback(() => setPop(null), []);
  const ref = useOutsideClose<HTMLDivElement>(pop !== null, close);
  const collections = useQuery({ queryKey: ["collections"], queryFn: () => api<Collection[]>("/collections") });

  const [cat, setCat] = useState<number | null>(null);
  const [addTags, setAddTags] = useState<string[]>([]);
  const [removeTags, setRemoveTags] = useState<string[]>([]);
  const [flagKind, setFlagKind] = useState<FlagKind>("broken_mesh");
  const [flagNote, setFlagNote] = useState("");
  const [newColl, setNewColl] = useState("");

  const run = async (body: Record<string, unknown>, msg: string) => {
    try {
      const r = await api<{ updated: number; skipped: number }>("/models/bulk", { method: "POST", json: { ids, ...body } });
      toast(r.skipped ? `${msg} (${r.skipped} skipped: not yours to delete)` : msg);
      setPop(null);
      qc.invalidateQueries();
      if (body.delete || body.restore) onClear();
    } catch (e) {
      toast((e as Error).message, true);
    }
  };

  const toggle = (p: Pop) => setPop(pop === p ? null : p);
  const n = ids.length;

  if (trashed)
    return (
      <div className="bulkbar">
        <span className="count">{n} selected</span>
        <button onClick={() => run({ restore: true }, `Restored ${n}`)}>Restore</button>
        <button className="ghost icon" onClick={onClear} title="Clear selection">
          <Icon name="close" />
        </button>
      </div>
    );

  return (
    <div className="bulkbar" ref={ref}>
      <span className="count">{n} selected</span>

      <div className="rel">
        <button className={pop === "category" ? "active" : ""} onClick={() => toggle("category")}>
          Category
        </button>
        {pop === "category" && (
          <div className="popover">
            <CategorySelect value={cat} onChange={setCat} noneLabel="— Clear category —" />
            <button className="primary" onClick={() => run(cat ? { category_id: cat } : { clear_category: true }, `Categorised ${n}`)}>
              Apply to {n}
            </button>
          </div>
        )}
      </div>

      <div className="rel">
        <button className={pop === "tags" ? "active" : ""} onClick={() => toggle("tags")}>
          Tags
        </button>
        {pop === "tags" && (
          <div className="popover" style={{ minWidth: 320 }}>
            <label className="field">
              Add tags
              <TagInput value={addTags} onChange={setAddTags} />
            </label>
            <label className="field">
              Remove tags
              <TagInput value={removeTags} onChange={setRemoveTags} placeholder="Tags to remove…" />
            </label>
            <button
              className="primary"
              disabled={!addTags.length && !removeTags.length}
              onClick={() => run({ add_tags: addTags, remove_tags: removeTags }, `Updated tags on ${n}`).then(() => (setAddTags([]), setRemoveTags([])))}
            >
              Apply to {n}
            </button>
          </div>
        )}
      </div>

      <div className="rel">
        <button className={pop === "status" ? "active" : ""} onClick={() => toggle("status")}>
          Status
        </button>
        {pop === "status" && (
          <div className="popover" style={{ minWidth: 200 }}>
            {(Object.keys(STATUS_LABELS) as (keyof typeof STATUS_LABELS)[]).map((s) => (
              <button key={s} onClick={() => run({ status: s }, `Marked ${n} as ${STATUS_LABELS[s]}`)}>
                {STATUS_LABELS[s]}
              </button>
            ))}
            <button className="ghost" onClick={() => run({ status: "" }, `Cleared status on ${n}`)}>
              Clear status
            </button>
          </div>
        )}
      </div>

      <button onClick={() => run({ favourite: true }, `Favourited ${n}`)} title="Favourite">
        <Icon name="heart" />
      </button>

      <div className="rel">
        <button className={pop === "flag" ? "active" : ""} onClick={() => toggle("flag")} title="Flag a problem">
          <Icon name="flag" />
        </button>
        {pop === "flag" && (
          <div className="popover">
            <select value={flagKind} onChange={(e) => setFlagKind(e.target.value as FlagKind)}>
              {(Object.keys(FLAG_LABELS) as FlagKind[]).map((k) => (
                <option key={k} value={k}>
                  {FLAG_LABELS[k]}
                </option>
              ))}
            </select>
            <input placeholder="Note (optional)" value={flagNote} onChange={(e) => setFlagNote(e.target.value)} />
            <button className="primary" onClick={() => run({ add_flag: { kind: flagKind, note: flagNote } }, `Flagged ${n}`)}>
              Flag {n}
            </button>
          </div>
        )}
      </div>

      <div className="rel">
        <button className={pop === "collection" ? "active" : ""} onClick={() => toggle("collection")}>
          Collection
        </button>
        {pop === "collection" && (
          <div className="popover">
            {collections.data
              ?.filter((c) => c.kind === "manual")
              .map((c) => (
                <button key={c.id} onClick={() => run({ add_to_collection: c.id }, `Added ${n} to ${c.name}`)}>
                  {c.name}
                </button>
              ))}
            <div className="row">
              <input placeholder="New collection…" value={newColl} onChange={(e) => setNewColl(e.target.value)} />
              <button
                disabled={!newColl.trim()}
                onClick={async () => {
                  const c = await api<Collection>("/collections", { method: "POST", json: { name: newColl, kind: "manual" } });
                  setNewColl("");
                  run({ add_to_collection: c.id }, `Added ${n} to ${c.name}`);
                }}
              >
                Create
              </button>
            </div>
          </div>
        )}
      </div>

      <button onClick={() => run({ untriaged: false }, `Marked ${n} as triaged`)} title="Remove from Untriaged">
        <Icon name="check" /> Triaged
      </button>
      <button className="danger" onClick={() => run({ delete: true }, `Moved ${n} to trash`)} title="Move to trash">
        <Icon name="trash" />
      </button>
      <button className="ghost icon" onClick={onClear} title="Clear selection (Esc)">
        <Icon name="close" />
      </button>
    </div>
  );
}
