import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useQuery } from "@tanstack/react-query";
import { api, type Category, type Tag } from "../api";

/* ---------------------------------------------------------------- icons */

const paths: Record<string, string> = {
  search: "M11 4a7 7 0 1 0 4.2 12.6l4.1 4.1 1.4-1.4-4.1-4.1A7 7 0 0 0 11 4zm0 2a5 5 0 1 1 0 10 5 5 0 0 1 0-10z",
  upload: "M12 3 6.5 8.5l1.4 1.4L11 6.8V16h2V6.8l3.1 3.1 1.4-1.4zM5 18v2h14v-2z",
  grid: "M4 4h7v7H4zm9 0h7v7h-7zM4 13h7v7H4zm9 0h7v7h-7z",
  inbox: "M4 4h16v10h-5a3 3 0 0 1-6 0H4zm0 12h3.5a5 5 0 0 0 9 0H20v4H4z",
  settings: "M12 8.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7zm8.4 4.6-1.9-.3a6.9 6.9 0 0 1-.6 1.5l1.1 1.6-1.6 1.6-1.6-1.1a7 7 0 0 1-1.5.6l-.3 1.9h-2.3l-.3-1.9a7 7 0 0 1-1.5-.6l-1.6 1.1-1.6-1.6 1.1-1.6a6.9 6.9 0 0 1-.6-1.5l-1.9-.3v-2.3l1.9-.3c.1-.5.3-1 .6-1.5L5.1 6.8l1.6-1.6 1.6 1.1c.5-.3 1-.5 1.5-.6l.3-1.9h2.3l.3 1.9c.5.1 1 .3 1.5.6l1.6-1.1 1.6 1.6-1.1 1.6c.3.5.5 1 .6 1.5l1.9.3z",
  heart: "M12 20s-7-4.4-9.2-8.6C1.4 8.6 3 5 6.4 5c2 0 3.3 1.1 4 2.3h3.2C14.3 6.1 15.6 5 17.6 5 21 5 22.6 8.6 21.2 11.4 19 15.6 12 20 12 20z",
  flag: "M5 3h2v18H5zm3 1h10l-2 4 2 4H8z",
  trash: "M9 3h6l1 2h4v2H4V5h4zm-3 6h12l-1 12H7z",
  download: "M11 4h2v9.2l3.1-3.1 1.4 1.4L12 17 6.5 11.5l1.4-1.4 3.1 3.1zM5 19h14v2H5z",
  close: "M6.4 5 12 10.6 17.6 5 19 6.4 13.4 12 19 17.6 17.6 19 12 13.4 6.4 19 5 17.6 10.6 12 5 6.4z",
  check: "M9.5 16.2 5.3 12l-1.4 1.4 5.6 5.6L20.1 8.4 18.7 7z",
  cube: "M12 2 21 7v10l-9 5-9-5V7zm0 2.3L5.4 8 12 11.7 18.6 8zM5 9.7v6.1l6 3.4v-6.1zm14 0-6 3.4v6.1l6-3.4z",
  filter: "M3 5h18l-7 8v6l-4 2v-8z",
  star: "M12 3.5 14.6 9l6 .6-4.5 4 1.3 5.9L12 16.6 6.6 19.5l1.3-5.9-4.5-4 6-.6z",
  external: "M14 4h6v6h-2V7.4l-7.3 7.3-1.4-1.4L16.6 6H14zM5 6h6v2H6v10h10v-5h2v7H4V6z",
  logout: "M10 4H4v16h6v-2H6V6h4zm5.6 3.4-1.4 1.4 2.2 2.2H9v2h7.4l-2.2 2.2 1.4 1.4L20.2 12z",
  folder: "M3 5h7l2 2h9v12H3z",
  wire: "M4 4h16v16H4zm2 2v4.6L10.6 6zm7.4 0L6 13.4v4.2L17.6 6zM18 9.2 9.2 18h4.2L18 13.4zm0 7L16.2 18H18z",
  refresh: "M17.7 6.3A8 8 0 1 0 20 12h-2a6 6 0 1 1-1.8-4.2L13 11h7V4z",
  menu: "M3 6h18v2H3zm0 5h18v2H3zm0 5h18v2H3z",
  link: "M10.6 13.4a1 1 0 0 0 1.4 0l4-4a3 3 0 1 0-4.2-4.2l-1.2 1.2 1.4 1.4 1.2-1.2a1 1 0 1 1 1.4 1.4l-4 4a1 1 0 0 0 0 1.4zm2.8-2.8a1 1 0 0 0-1.4 0l-4 4a3 3 0 1 0 4.2 4.2l1.2-1.2-1.4-1.4-1.2 1.2a1 1 0 1 1-1.4-1.4l4-4a1 1 0 0 0 0-1.4z",
};

export function Icon({ name, size = 16, className }: { name: keyof typeof paths | string; size?: number; className?: string }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" className={className} aria-hidden>
      <path d={paths[name] ?? paths.cube} />
    </svg>
  );
}

/* ---------------------------------------------------------------- toasts */

type Toast = { id: number; text: string; error?: boolean };
const ToastCtx = createContext<(text: string, error?: boolean) => void>(() => {});
export const useToast = () => useContext(ToastCtx);

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const push = useCallback((text: string, error = false) => {
    const id = Date.now() + Math.random();
    setToasts((t) => [...t, { id, text, error }]);
    setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), error ? 6000 : 3000);
  }, []);
  return (
    <ToastCtx.Provider value={push}>
      {children}
      <div className="toast-stack">
        {toasts.map((t) => (
          <div key={t.id} className={`toast ${t.error ? "error" : ""}`}>
            {t.text}
          </div>
        ))}
      </div>
    </ToastCtx.Provider>
  );
}

/* ---------------------------------------------------------------- data hooks */

export function useCategories() {
  return useQuery({ queryKey: ["categories"], queryFn: () => api<Category[]>("/categories") });
}

export function useTags() {
  return useQuery({ queryKey: ["tags"], queryFn: () => api<Tag[]>("/tags") });
}

export type CatNode = Category & { children: CatNode[]; depth: number; total: number };

export function buildTree(cats: Category[]): CatNode[] {
  const byId = new Map<number, CatNode>();
  cats.forEach((c) => byId.set(c.id, { ...c, children: [], depth: 0, total: c.count }));
  const roots: CatNode[] = [];
  byId.forEach((n) => (n.parent_id && byId.get(n.parent_id) ? byId.get(n.parent_id)!.children.push(n) : roots.push(n)));
  const walk = (nodes: CatNode[], depth: number): number =>
    nodes.reduce((sum, n) => {
      n.depth = depth;
      n.total = n.count + walk(n.children, depth + 1);
      return sum + n.total;
    }, 0);
  walk(roots, 0);
  return roots;
}

export function flattenTree(nodes: CatNode[]): CatNode[] {
  return nodes.flatMap((n) => [n, ...flattenTree(n.children)]);
}

export function categoryLabel(cats: Category[] | undefined, id: number | null): string {
  if (!cats || id == null) return "";
  const byId = new Map(cats.map((c) => [c.id, c]));
  const names: string[] = [];
  let c = byId.get(id);
  while (c) {
    names.unshift(c.name);
    c = c.parent_id ? byId.get(c.parent_id) : undefined;
  }
  return names.join(" › ");
}

/* ---------------------------------------------------------------- inputs */

export function CategorySelect({
  value,
  onChange,
  allowNone = true,
  noneLabel = "No category",
}: {
  value: number | null;
  onChange: (id: number | null) => void;
  allowNone?: boolean;
  noneLabel?: string;
}) {
  const { data: cats = [] } = useCategories();
  const flat = useMemo(() => flattenTree(buildTree(cats)), [cats]);
  return (
    <select value={value ?? ""} onChange={(e) => onChange(e.target.value ? Number(e.target.value) : null)}>
      {allowNone && <option value="">{noneLabel}</option>}
      {flat.map((c) => (
        <option key={c.id} value={c.id}>
          {"   ".repeat(c.depth)}
          {c.name}
        </option>
      ))}
    </select>
  );
}

export function TagInput({ value, onChange, placeholder = "Add tags…" }: { value: string[]; onChange: (tags: string[]) => void; placeholder?: string }) {
  const { data: all = [] } = useTags();
  const [text, setText] = useState("");
  const [hi, setHi] = useState(0);
  const [focus, setFocus] = useState(false);
  const q = text.trim().toLowerCase();
  const suggestions = useMemo(
    () => (q ? all.filter((t) => t.name.includes(q) && !value.includes(t.name)).slice(0, 8) : []),
    [all, q, value],
  );
  const add = (name: string) => {
    const n = name.trim().toLowerCase();
    if (n && !value.includes(n)) onChange([...value, n]);
    setText("");
    setHi(0);
  };
  return (
    <div className="taginput">
      {value.map((t) => (
        <span key={t} className="chip accent">
          {t}
          <button type="button" onClick={() => onChange(value.filter((x) => x !== t))} aria-label={`Remove ${t}`}>
            ×
          </button>
        </span>
      ))}
      <input
        value={text}
        placeholder={value.length ? "" : placeholder}
        onChange={(e) => {
          const v = e.target.value;
          if (v.endsWith(",")) add(v.slice(0, -1));
          else setText(v);
        }}
        onFocus={() => setFocus(true)}
        onBlur={() => setTimeout(() => setFocus(false), 150)}
        onKeyDown={(e) => {
          if (e.key === "Enter") {
            e.preventDefault();
            add(suggestions[hi]?.name ?? text);
          } else if (e.key === "Backspace" && !text && value.length) onChange(value.slice(0, -1));
          else if (e.key === "ArrowDown") setHi((h) => Math.min(h + 1, suggestions.length - 1));
          else if (e.key === "ArrowUp") setHi((h) => Math.max(h - 1, 0));
        }}
      />
      {focus && suggestions.length > 0 && (
        <div className="suggest">
          {suggestions.map((t, i) => (
            <div key={t.id} className={i === hi ? "hi" : ""} onMouseDown={() => add(t.name)}>
              {t.name}
              <span className="faint">{t.count}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

export function Stars({ value, onChange }: { value: number | null; onChange: (v: number) => void }) {
  return (
    <span className="stars">
      {[1, 2, 3, 4, 5].map((n) => (
        <button key={n} className={value && n <= value ? "on" : ""} onClick={() => onChange(value === n ? 0 : n)} title={`${n} star${n > 1 ? "s" : ""}`}>
          ★
        </button>
      ))}
    </span>
  );
}

export function Modal({ children, onClose }: { children: ReactNode; onClose: () => void }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  return (
    <div className="modal-back" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="modal card">{children}</div>
    </div>
  );
}

/** Close a popover when clicking outside it. */
export function useOutsideClose<T extends HTMLElement>(open: boolean, close: () => void) {
  const ref = useRef<T>(null);
  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => ref.current && !ref.current.contains(e.target as Node) && close();
    document.addEventListener("mousedown", onDown);
    return () => document.removeEventListener("mousedown", onDown);
  }, [open, close]);
  return ref;
}
