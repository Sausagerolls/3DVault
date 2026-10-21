import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { FLAG_LABELS, STATUS_LABELS, api, type Collection, type Printer, type User } from "../api";
import { buildTree, Icon, useCategories, useTags, type CatNode } from "./ui";

export type Filters = Record<string, string | string[]>;

type Props = {
  filters: Filters;
  locked: Filters;
  set: (key: string, value: string | string[] | null) => void;
  toggleIn: (key: string, value: string) => void;
  open: boolean;
};

const EXTS = ["stl", "3mf", "obj", "ply", "step", "gcode", "bgcode"];

const has = (v: string | string[] | undefined, x: string) => (Array.isArray(v) ? v.includes(x) : v === x);

export function Sidebar({ filters, locked, set, toggleIn, open }: Props) {
  const { data: cats = [] } = useCategories();
  const { data: tags = [] } = useTags();
  const printers = useQuery({ queryKey: ["printers"], queryFn: () => api<Printer[]>("/printers") });
  const users = useQuery({ queryKey: ["users"], queryFn: () => api<User[]>("/users") });
  const collections = useQuery({ queryKey: ["collections"], queryFn: () => api<Collection[]>("/collections") });
  const tree = useMemo(() => buildTree(cats), [cats]);
  const uncategorised = useQuery({
    queryKey: ["uncat-count"],
    queryFn: () => api<{ total: number }>("/models?category_id=-1&page_size=1"),
  });
  const [tagQuery, setTagQuery] = useState("");
  const [showAllTags, setShowAllTags] = useState(false);
  const shownTags = tags.filter((t) => t.name.includes(tagQuery.toLowerCase()));
  const tagLimit = showAllTags || tagQuery ? 200 : 30;

  const facet = (on: boolean, onClick: () => void, label: React.ReactNode, count?: number | null, extra?: React.ReactNode) => (
    <div className={`facet ${on ? "on" : ""}`} onClick={onClick}>
      {extra}
      <span className="ellipsis">{label}</span>
      {count != null && <span className="count">{count}</span>}
    </div>
  );

  return (
    <aside className={`sidebar ${open ? "open" : ""}`}>
      <section>
        {facet(!!filters.favourite, () => set("favourite", filters.favourite ? null : "true"), "Favourites", null, <Icon name="heart" />)}
        {facet(filters.flagged === "true", () => set("flagged", filters.flagged === "true" ? null : "true"), "Has problems", null, <Icon name="flag" />)}
        {!locked.trashed && (
          <Link to="/trash" className="facet">
            <Icon name="trash" />
            <span>Trash</span>
          </Link>
        )}
      </section>

      {!!collections.data?.length && (
        <section>
          <h3>Collections</h3>
          {collections.data.map((c) =>
            facet(
              filters.collection_id === String(c.id),
              () => set("collection_id", filters.collection_id === String(c.id) ? null : String(c.id)),
              c.name,
              c.count,
              <Icon name={c.kind === "smart" ? "filter" : "folder"} />,
            ),
          )}
        </section>
      )}

      <section>
        <h3>Categories</h3>
        {facet(!filters.category_id, () => set("category_id", null), "All")}
        {tree.map((n) => (
          <CatRow key={n.id} node={n} selected={filters.category_id as string} onPick={(id) => set("category_id", id)} />
        ))}
        {facet(filters.category_id === "-1", () => set("category_id", filters.category_id === "-1" ? null : "-1"), <i>Uncategorised</i>, uncategorised.data?.total)}
      </section>

      <section>
        <h3>My print status</h3>
        {(Object.keys(STATUS_LABELS) as (keyof typeof STATUS_LABELS)[]).map((s) =>
          facet(has(filters.status, s), () => toggleIn("status", s), STATUS_LABELS[s]),
        )}
        {facet(has(filters.status, "none"), () => toggleIn("status", "none"), <i>No status</i>)}
        <div className="facet" style={{ cursor: "default" }}>
          <span>Min rating</span>
          <select
            style={{ marginLeft: "auto", width: 80, minHeight: 26, padding: "2px 6px" }}
            value={(filters.min_rating as string) ?? ""}
            onChange={(e) => set("min_rating", e.target.value || null)}
          >
            <option value="">Any</option>
            {[1, 2, 3, 4, 5].map((n) => (
              <option key={n} value={n}>
                {"★".repeat(n)}
              </option>
            ))}
          </select>
        </div>
      </section>

      <section>
        <h3>Tags</h3>
        {tags.length > 12 && (
          <input placeholder="Filter tags…" value={tagQuery} onChange={(e) => setTagQuery(e.target.value)} style={{ marginBottom: 6 }} />
        )}
        <div className="tagcloud">
          {shownTags.slice(0, tagLimit).map((t) => (
            <span key={t.id} className={`chip ${has(filters.tags, t.name) ? "on" : ""}`} onClick={() => toggleIn("tags", t.name)}>
              {t.name} <span className="faint">{t.count}</span>
            </span>
          ))}
          {!tags.length && <span className="faint" style={{ padding: "0 4px" }}>No tags yet</span>}
        </div>
        {shownTags.length > tagLimit && (
          <button className="ghost small" onClick={() => setShowAllTags(true)}>
            Show all {shownTags.length}
          </button>
        )}
      </section>

      <section>
        <h3>Fits printer</h3>
        {printers.data?.map((p) =>
          facet(
            filters.printer_id === String(p.id),
            () => set("printer_id", filters.printer_id === String(p.id) ? null : String(p.id)),
            p.name,
            null,
          ),
        )}
      </section>

      <section>
        <h3>File type</h3>
        <div className="tagcloud">
          {EXTS.map((e) => (
            <span key={e} className={`chip ${has(filters.ext, e) ? "on" : ""}`} onClick={() => toggleIn("ext", e)}>
              .{e}
            </span>
          ))}
        </div>
      </section>

      <section>
        <h3>Problems</h3>
        {(Object.keys(FLAG_LABELS) as (keyof typeof FLAG_LABELS)[]).map((k) =>
          facet(has(filters.flag_kind, k), () => toggleIn("flag_kind", k), FLAG_LABELS[k]),
        )}
      </section>

      <section>
        <h3>Geometry</h3>
        <RangeRow label="Parts" min={filters.min_parts as string} max={filters.max_parts as string} onMin={(v) => set("min_parts", v)} onMax={(v) => set("max_parts", v)} />
        <RangeRow label="Triangles" min={filters.min_tris as string} max={filters.max_tris as string} onMin={(v) => set("min_tris", v)} onMax={(v) => set("max_tris", v)} />
      </section>

      {(users.data?.length ?? 0) > 1 && (
        <section>
          <h3>Uploaded by</h3>
          {users.data!.map((u) =>
            facet(filters.uploader_id === String(u.id), () => set("uploader_id", filters.uploader_id === String(u.id) ? null : String(u.id)), u.display_name),
          )}
        </section>
      )}

      <section>
        <h3>Added</h3>
        <div className="row" style={{ padding: "0 4px" }}>
          <input type="date" value={(filters.added_after as string) ?? ""} onChange={(e) => set("added_after", e.target.value || null)} title="From" />
          <input type="date" value={(filters.added_before as string) ?? ""} onChange={(e) => set("added_before", e.target.value || null)} title="To" />
        </div>
      </section>
    </aside>
  );
}

function CatRow({ node, selected, onPick }: { node: CatNode; selected: string; onPick: (id: string | null) => void }) {
  const [open, setOpen] = useState(node.depth === 0 && node.children.length < 8);
  const on = selected === String(node.id);
  return (
    <>
      <div className={`facet ${on ? "on" : ""}`} style={{ paddingLeft: 6 + node.depth * 14 }} onClick={() => onPick(on ? null : String(node.id))}>
        <span
          className="twisty"
          onClick={(e) => {
            e.stopPropagation();
            setOpen(!open);
          }}
        >
          {node.children.length ? (open ? "▾" : "▸") : ""}
        </span>
        <span className="ellipsis">{node.name}</span>
        <span className="count">{node.total}</span>
      </div>
      {open && node.children.map((c) => <CatRow key={c.id} node={c} selected={selected} onPick={onPick} />)}
    </>
  );
}

function RangeRow({ label, min, max, onMin, onMax }: { label: string; min?: string; max?: string; onMin: (v: string | null) => void; onMax: (v: string | null) => void }) {
  const style = { minHeight: 26, padding: "2px 6px", width: 70 };
  return (
    <div className="facet" style={{ cursor: "default" }}>
      <span>{label}</span>
      <span className="row" style={{ marginLeft: "auto", gap: 4 }}>
        <input style={style} inputMode="numeric" placeholder="min" defaultValue={min ?? ""} onBlur={(e) => onMin(e.target.value || null)} />
        <input style={style} inputMode="numeric" placeholder="max" defaultValue={max ?? ""} onBlur={(e) => onMax(e.target.value || null)} />
      </span>
    </div>
  );
}
