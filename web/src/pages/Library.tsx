import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useInfiniteQuery, useQuery, useQueryClient } from "@tanstack/react-query";
import { useNavigate, useSearchParams } from "react-router-dom";
import { FLAG_LABELS, STATUS_LABELS, api, type Collection, type ModelSummary, type Page, type Printer, type Status, type FlagKind } from "../api";
import { BulkBar } from "../components/BulkBar";
import { HoverStageProvider } from "../components/HoverStage";
import { ModelCard } from "../components/ModelCard";
import { Sidebar, type Filters } from "../components/Sidebar";
import { Icon, categoryLabel, useCategories, useToast } from "../components/ui";

const MULTI = new Set(["tags", "status", "ext", "flag_kind"]);
const PAGE = 60;

function readFilters(params: URLSearchParams): Filters {
  const out: Filters = {};
  params.forEach((_, k) => {
    out[k] = MULTI.has(k) ? params.getAll(k) : params.get(k)!;
  });
  return out;
}

function toQuery(f: Filters): string {
  const p = new URLSearchParams();
  Object.entries(f).forEach(([k, v]) => (Array.isArray(v) ? v.forEach((x) => p.append(k, x)) : v && p.set(k, v)));
  return p.toString();
}

export default function Library({ preset = {}, title = "Library" }: { preset?: Filters; title?: string }) {
  const [params, setParams] = useSearchParams();
  const navigate = useNavigate();
  const qc = useQueryClient();
  const toast = useToast();
  const { data: cats } = useCategories();
  const printers = useQuery({ queryKey: ["printers"], queryFn: () => api<Printer[]>("/printers") });
  const collections = useQuery({ queryKey: ["collections"], queryFn: () => api<Collection[]>("/collections") });
  const userFilters = useMemo(() => readFilters(params), [params]);
  const filters = useMemo(() => ({ ...userFilters, ...preset }), [userFilters, preset]);
  const query = toQuery(filters);
  const trashed = preset.trashed === "true";

  const [cardW, setCardW] = useState(() => Number(safeGet("vault.cardW")) || 210);
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const lastClicked = useRef<number | null>(null);

  const list = useInfiniteQuery({
    queryKey: ["models", query],
    queryFn: ({ pageParam }) => api<Page<ModelSummary>>(`/models?${query}&page=${pageParam}&page_size=${PAGE}`),
    initialPageParam: 1,
    getNextPageParam: (last) => (last.page * last.page_size < last.total ? last.page + 1 : undefined),
    // Poll while thumbnails are still being generated.
    refetchInterval: (q) => (q.state.data?.pages.some((p) => p.items.some((m) => m.processing)) ? 4000 : false),
  });
  const items = useMemo(() => list.data?.pages.flatMap((p) => p.items) ?? [], [list.data]);
  const total = list.data?.pages[0]?.total ?? 0;

  useEffect(() => setSelected(new Set()), [query]);

  const set = useCallback(
    (key: string, value: string | string[] | null) => {
      const next = new URLSearchParams(params);
      next.delete(key);
      if (Array.isArray(value)) value.forEach((v) => next.append(key, v));
      else if (value) next.set(key, value);
      setParams(next, { replace: true });
    },
    [params, setParams],
  );
  const toggleIn = useCallback(
    (key: string, value: string) => {
      const cur = params.getAll(key);
      set(key, cur.includes(value) ? cur.filter((x) => x !== value) : [...cur, value]);
    },
    [params, set],
  );

  // Infinite scroll sentinel.
  const sentinel = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = sentinel.current;
    if (!el) return;
    const obs = new IntersectionObserver((e) => e[0].isIntersecting && list.hasNextPage && !list.isFetchingNextPage && list.fetchNextPage(), {
      rootMargin: "600px",
    });
    obs.observe(el);
    return () => obs.disconnect();
  }, [list]);

  // Keyboard: Cmd/Ctrl+A select all loaded, Esc clears.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const tag = (e.target as HTMLElement).tagName;
      if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return;
      if ((e.metaKey || e.ctrlKey) && e.key === "a") {
        e.preventDefault();
        setSelected(new Set(items.map((m) => m.id)));
      } else if (e.key === "Escape") setSelected(new Set());
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [items]);

  const toggle = useCallback(
    (e: React.MouseEvent, m: ModelSummary) => {
      setSelected((prev) => {
        const next = new Set(prev);
        if (e.shiftKey && lastClicked.current != null) {
          const a = items.findIndex((x) => x.id === lastClicked.current);
          const b = items.findIndex((x) => x.id === m.id);
          const [lo, hi] = a < b ? [a, b] : [b, a];
          items.slice(lo, hi + 1).forEach((x) => next.add(x.id));
        } else if (next.has(m.id)) next.delete(m.id);
        else next.add(m.id);
        return next;
      });
      lastClicked.current = m.id;
    },
    [items],
  );

  const onCardClick = useCallback(
    (e: React.MouseEvent, m: ModelSummary) => {
      if (e.metaKey || e.ctrlKey || e.shiftKey || selected.size > 0) toggle(e, m);
      else navigate(`/models/${m.id}`);
    },
    [navigate, selected.size, toggle],
  );

  const saveSmart = async () => {
    const name = window.prompt("Name this smart collection");
    if (!name) return;
    const { collection_id: _c, ...rest } = userFilters;
    await api("/collections", { method: "POST", json: { name, kind: "smart", query: rest } });
    qc.invalidateQueries({ queryKey: ["collections"] });
    toast(`Saved “${name}”`);
  };

  const chips = activeChips(userFilters, cats, printers.data, collections.data);

  return (
    <HoverStageProvider>
      <div className="library">
        <Sidebar filters={filters} locked={preset} set={set} toggleIn={toggleIn} open={sidebarOpen} />
        <div className="content" onClick={() => sidebarOpen && setSidebarOpen(false)}>
          <div className="toolbar">
            <button className="ghost icon only-mobile" onClick={(e) => (e.stopPropagation(), setSidebarOpen(!sidebarOpen))}>
              <Icon name="menu" />
            </button>
            <h2>{title}</h2>
            <span className="faint">{list.isLoading ? "…" : `${total} model${total === 1 ? "" : "s"}`}</span>
            {chips.map((c) => (
              <span key={c.key + c.value} className="chip accent">
                {c.label}
                <button onClick={() => (MULTI.has(c.key) ? toggleIn(c.key, c.value) : set(c.key, null))}>×</button>
              </span>
            ))}
            {chips.length > 1 && (
              <button className="ghost small" onClick={() => setParams(new URLSearchParams(), { replace: true })}>
                Clear all
              </button>
            )}
            <span className="spacer" />
            {chips.length > 0 && !trashed && (
              <button className="small" onClick={saveSmart} title="Save these filters as a smart collection">
                <Icon name="filter" size={13} /> Save
              </button>
            )}
            {trashed && total > 0 && (
              <button
                className="small danger"
                onClick={async () => {
                  if (!window.confirm("Permanently delete everything in the trash? This cannot be undone.")) return;
                  await api("/trash/empty", { method: "POST" });
                  qc.invalidateQueries();
                }}
              >
                Empty trash
              </button>
            )}
            <select value={(userFilters.sort as string) ?? "new"} onChange={(e) => set("sort", e.target.value === "new" ? null : e.target.value)}>
              <option value="new">Newest</option>
              <option value="old">Oldest</option>
              <option value="name">Name</option>
              <option value="updated">Recently edited</option>
              <option value="rating">My rating</option>
              <option value="size">Largest</option>
              <option value="tris">Most triangles</option>
            </select>
            <input
              type="range"
              min={140}
              max={340}
              value={cardW}
              style={{ width: 90 }}
              title="Card size"
              onChange={(e) => {
                setCardW(Number(e.target.value));
                safeSet("vault.cardW", e.target.value);
              }}
            />
          </div>
          <div className="grid-wrap">
            {trashed && <p className="dim" style={{ marginTop: 0 }}>Items in the trash are deleted for good after 30 days.</p>}
            {list.error && <div className="error-box">{(list.error as Error).message}</div>}
            {!list.isLoading && items.length === 0 && (
              <div className="empty">
                {chips.length || preset.untriaged || trashed ? (
                  preset.untriaged ? "Nothing waiting. Everything is categorised." : trashed ? "Trash is empty." : "No models match these filters."
                ) : (
                  <>
                    <p>Your library is empty.</p>
                    <button className="primary" onClick={() => navigate("/upload")}>
                      <Icon name="upload" /> Upload models
                    </button>
                  </>
                )}
              </div>
            )}
            <div className={`grid ${selected.size ? "selecting" : ""}`} style={{ "--card-w": `${cardW}px` } as React.CSSProperties}>
              {items.map((m) => (
                <ModelCard key={m.id} model={m} selected={selected.has(m.id)} onClick={onCardClick} onToggle={toggle} />
              ))}
            </div>
            <div ref={sentinel} style={{ height: 1 }} />
            {list.isFetchingNextPage && <p className="faint" style={{ textAlign: "center" }}>Loading…</p>}
          </div>
          {selected.size > 0 && <BulkBar ids={[...selected]} trashed={trashed} onClear={() => setSelected(new Set())} />}
        </div>
      </div>
    </HoverStageProvider>
  );
}

function activeChips(f: Filters, cats: ReturnType<typeof useCategories>["data"], printers?: Printer[], colls?: Collection[]) {
  const out: { key: string; value: string; label: string }[] = [];
  const add = (key: string, value: string, label: string) => out.push({ key, value, label });
  for (const [k, v] of Object.entries(f)) {
    const vals = Array.isArray(v) ? v : [v];
    for (const x of vals) {
      if (!x) continue;
      switch (k) {
        case "q": add(k, x, `“${x}”`); break;
        case "category_id": add(k, x, x === "-1" ? "Uncategorised" : categoryLabel(cats, Number(x)) || "Category"); break;
        case "tags": add(k, x, `#${x}`); break;
        case "status": add(k, x, x === "none" ? "No status" : STATUS_LABELS[x as Status]); break;
        case "flag_kind": add(k, x, FLAG_LABELS[x as FlagKind]); break;
        case "ext": add(k, x, `.${x}`); break;
        case "favourite": add(k, x, "Favourites"); break;
        case "flagged": add(k, x, "Has problems"); break;
        case "min_rating": add(k, x, `≥ ${"★".repeat(Number(x))}`); break;
        case "printer_id": add(k, x, `Fits ${printers?.find((p) => String(p.id) === x)?.name ?? "printer"}`); break;
        case "collection_id": add(k, x, colls?.find((c) => String(c.id) === x)?.name ?? "Collection"); break;
        case "uploader_id": add(k, x, "Uploader"); break;
        case "added_after": add(k, x, `After ${x}`); break;
        case "added_before": add(k, x, `Before ${x}`); break;
        case "min_parts": add(k, x, `≥ ${x} parts`); break;
        case "max_parts": add(k, x, `≤ ${x} parts`); break;
        case "min_tris": add(k, x, `≥ ${x} tris`); break;
        case "max_tris": add(k, x, `≤ ${x} tris`); break;
      }
    }
  }
  return out;
}

function safeGet(k: string): string | null {
  try {
    return localStorage.getItem(k);
  } catch {
    return null;
  }
}
function safeSet(k: string, v: string) {
  try {
    localStorage.setItem(k, v);
  } catch {
    /* ignore */
  }
}
