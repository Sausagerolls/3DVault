import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { api, type Collection, type Machine, type MachineKind, type Printer, type Rule, type User } from "../api";
import { useUser } from "../App";
import { CategorySelect, Icon, TagInput, buildTree, flattenTree, useCategories, useTags, useToast } from "../components/ui";

const TABS = ["Account", "Categories", "Tags", "Printers", "Auto-tag rules", "Collections", "Users", "System"] as const;
type Tab = (typeof TABS)[number];
const ADMIN_TABS: Tab[] = ["Users", "System"];

export default function Settings() {
  const user = useUser();
  const [tab, setTab] = useState<Tab>("Account");
  return (
    <div className="page">
      <div className="page narrow" style={{ padding: 0 }}>
        <h1 style={{ marginBottom: 16 }}>Settings</h1>
        <div className="tabs">
          {TABS.filter((t) => user.role === "admin" || !ADMIN_TABS.includes(t)).map((t) => (
            <button key={t} className={tab === t ? "on" : ""} onClick={() => setTab(t)}>
              {t}
            </button>
          ))}
        </div>
        {tab === "Account" && <Account />}
        {tab === "Categories" && <Categories />}
        {tab === "Tags" && <Tags />}
        {tab === "Printers" && (
          <>
            {user.role === "admin" && <Machines />}
            <Printers />
          </>
        )}
        {tab === "Auto-tag rules" && <Rules />}
        {tab === "Collections" && <Collections />}
        {tab === "Users" && <Users />}
        {tab === "System" && <System />}
      </div>
    </div>
  );
}

function useInvalidate() {
  const qc = useQueryClient();
  return (...keys: string[]) => keys.forEach((k) => qc.invalidateQueries({ queryKey: [k] }));
}

function useRun() {
  const toast = useToast();
  return async (fn: () => Promise<unknown>, ok?: string) => {
    try {
      await fn();
      if (ok) toast(ok);
      return true;
    } catch (e) {
      toast((e as Error).message, true);
      return false;
    }
  };
}

/* ---------------------------------------------------------------- account */

type TokenRow = { id: number; kind: string; name: string; created_at: string; last_used_at: string | null; current: boolean };

function Account() {
  const run = useRun();
  const inv = useInvalidate();
  const tokens = useQuery({ queryKey: ["tokens"], queryFn: () => api<TokenRow[]>("/tokens") });
  const [cur, setCur] = useState("");
  const [next, setNext] = useState("");
  const [newToken, setNewToken] = useState<string | null>(null);
  const [tokenName, setTokenName] = useState("");
  return (
    <div className="col" style={{ gap: 20 }}>
      <section className="panel col" style={{ maxWidth: 420 }}>
        <h2>Change password</h2>
        <input type="password" placeholder="Current password" value={cur} onChange={(e) => setCur(e.target.value)} autoComplete="current-password" />
        <input type="password" placeholder="New password (8+ characters)" value={next} onChange={(e) => setNext(e.target.value)} autoComplete="new-password" />
        <button
          className="primary"
          disabled={!cur || next.length < 8}
          onClick={async () => (await run(() => api("/auth/password", { method: "POST", json: { current_password: cur, new_password: next } }), "Password changed")) && (setCur(""), setNext(""))}
        >
          Change password
        </button>
      </section>

      <section className="panel col">
        <h2>Signed-in devices and app tokens</h2>
        <p className="dim" style={{ margin: 0 }}>The Mac app signs in and gets its own token. Revoke a token to sign that device out.</p>
        <table className="list">
          <thead>
            <tr>
              <th>Name</th>
              <th>Type</th>
              <th>Last used</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {tokens.data?.map((t) => (
              <tr key={t.id}>
                <td className="ellipsis" style={{ maxWidth: 360 }}>
                  {t.name || "—"} {t.current && <span className="chip accent">this browser</span>}
                </td>
                <td>{t.kind === "device" ? "App token" : "Browser"}</td>
                <td className="dim">{t.last_used_at ? new Date(t.last_used_at + "Z").toLocaleString() : "never"}</td>
                <td style={{ textAlign: "right" }}>
                  {!t.current && (
                    <button className="small danger" onClick={() => run(() => api(`/tokens/${t.id}`, { method: "DELETE" })).then(() => inv("tokens"))}>
                      Revoke
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        <div className="row">
          <input placeholder="Token name, e.g. Scripts" value={tokenName} onChange={(e) => setTokenName(e.target.value)} style={{ maxWidth: 260 }} />
          <button
            disabled={!tokenName}
            onClick={async () => {
              const r = await api<{ token: string }>(`/tokens?name=${encodeURIComponent(tokenName)}`, { method: "POST" });
              setNewToken(r.token);
              setTokenName("");
              inv("tokens");
            }}
          >
            Create API token
          </button>
        </div>
        {newToken && (
          <div className="panel col" style={{ background: "var(--bg-sunken)" }}>
            <span className="dim">Copy this now. It is not shown again.</span>
            <code style={{ userSelect: "all", overflowWrap: "anywhere" }}>{newToken}</code>
          </div>
        )}
      </section>
    </div>
  );
}

/* ---------------------------------------------------------------- categories */

function Categories() {
  const { data: cats = [] } = useCategories();
  const inv = useInvalidate();
  const run = useRun();
  const flat = flattenTree(buildTree(cats));
  const [name, setName] = useState("");
  const [parent, setParent] = useState<number | null>(null);
  const refresh = () => inv("categories", "models");
  return (
    <section className="panel col">
      <div className="row wrap">
        <input placeholder="New category name" value={name} onChange={(e) => setName(e.target.value)} style={{ maxWidth: 260 }} />
        <div style={{ width: 240 }}>
          <CategorySelect value={parent} onChange={setParent} noneLabel="Top level" />
        </div>
        <button
          className="primary"
          disabled={!name.trim()}
          onClick={async () => (await run(() => api("/categories", { method: "POST", json: { name, parent_id: parent } }))) && (setName(""), refresh())}
        >
          Add
        </button>
      </div>
      <table className="list">
        <thead>
          <tr>
            <th>Name</th>
            <th>Parent</th>
            <th>Models</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {flat.map((c) => (
            <tr key={c.id}>
              <td style={{ paddingLeft: 8 + c.depth * 20 }}>
                <input
                  defaultValue={c.name}
                  onBlur={(e) => e.target.value !== c.name && run(() => api(`/categories/${c.id}`, { method: "PATCH", json: { name: e.target.value, parent_id: c.parent_id } })).then(refresh)}
                />
              </td>
              <td style={{ width: 220 }}>
                <CategorySelect
                  value={c.parent_id}
                  noneLabel="Top level"
                  onChange={(pid) => run(() => api(`/categories/${c.id}`, { method: "PATCH", json: { name: c.name, parent_id: pid } })).then(refresh)}
                />
              </td>
              <td className="dim">{c.total}</td>
              <td style={{ textAlign: "right" }}>
                <button
                  className="small danger"
                  onClick={() =>
                    window.confirm(`Delete “${c.name}”? Its models and subcategories move up one level.`) &&
                    run(() => api(`/categories/${c.id}`, { method: "DELETE" })).then(refresh)
                  }
                >
                  Delete
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      {!flat.length && <p className="faint">No categories yet. Try Tools, Household, Toys, Printer parts, Organisers.</p>}
    </section>
  );
}

/* ---------------------------------------------------------------- tags */

function Tags() {
  const { data: tags = [] } = useTags();
  const inv = useInvalidate();
  const run = useRun();
  const [filter, setFilter] = useState("");
  const shown = tags.filter((t) => t.name.includes(filter.toLowerCase()));
  return (
    <section className="panel col">
      <p className="dim" style={{ margin: 0 }}>Rename a tag to an existing name to merge them.</p>
      <input placeholder="Filter…" value={filter} onChange={(e) => setFilter(e.target.value)} style={{ maxWidth: 260 }} />
      <table className="list">
        <thead>
          <tr>
            <th>Tag</th>
            <th>Models</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {shown.map((t) => (
            <tr key={t.id}>
              <td>
                <input
                  defaultValue={t.name}
                  onBlur={(e) => e.target.value.trim() && e.target.value !== t.name && run(() => api(`/tags/${t.id}`, { method: "PATCH", json: { name: e.target.value } })).then(() => inv("tags", "models"))}
                />
              </td>
              <td className="dim">{t.count}</td>
              <td style={{ textAlign: "right" }}>
                <Link className="btn small" to={`/?tags=${encodeURIComponent(t.name)}`}>
                  View
                </Link>{" "}
                <button className="small danger" onClick={() => window.confirm(`Remove tag “${t.name}” from all models?`) && run(() => api(`/tags/${t.id}`, { method: "DELETE" })).then(() => inv("tags", "models"))}>
                  Delete
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}

/* ---------------------------------------------------------------- connected printers */

type MachineForm = {
  id?: number;
  name: string;
  kind: string;
  host: string;
  serial: string;
  secret: string;
  printer_id: number | null;
  enabled: boolean;
  slicer_printer: string;
  has_secret?: boolean;
};

const EMPTY_MACHINE: MachineForm = { name: "", kind: "", host: "", serial: "", secret: "", printer_id: null, enabled: true, slicer_printer: "" };

type SlicerPrinter = { name: string; vendor: string; model: string; user: boolean };

/** Search box over Orca's printer profiles; there are about a thousand. */
function SlicerPrinterInput({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  const [q, setQ] = useState(value);
  const found = useQuery({
    queryKey: ["slicer-printers", q],
    queryFn: () => api<SlicerPrinter[]>(`/slicer/printers?q=${encodeURIComponent(q)}&limit=30`),
    enabled: q.length >= 2,
  });
  return (
    <>
      <input
        list="slicer-printers"
        value={q}
        placeholder="Bambu Lab A1 mini 0.4 nozzle"
        onChange={(e) => {
          setQ(e.target.value);
          onChange(e.target.value);
        }}
      />
      <datalist id="slicer-printers">
        {found.data?.map((p) => (
          <option key={p.vendor + p.name} value={p.name}>
            {p.user ? "Imported" : p.vendor}
          </option>
        ))}
      </datalist>
    </>
  );
}

function SlicerProfiles() {
  const status = useQuery({ queryKey: ["slicer"], queryFn: () => api<{ available: boolean }>("/slicer") });
  const run = useRun();
  const inv = useInvalidate();
  if (!status.data?.available) {
    return <p className="dim" style={{ margin: 0 }}>Slicing isn't available in this server image, so only pre-sliced files can be printed.</p>;
  }
  return (
    <div className="row" style={{ gap: 8 }}>
      <span className="dim">Import printer, process or filament presets exported from OrcaSlicer or Bambu Studio.</span>
      <span className="spacer" />
      <label className="btn small">
        Import presets…
        <input
          type="file"
          multiple
          accept=".json,.zip,.orca_printer,.orca_filament,.bbscfg,.bbsflmt"
          style={{ display: "none" }}
          onChange={async (e) => {
            const files = Array.from(e.target.files ?? []);
            e.target.value = "";
            if (!files.length) return;
            const form = new FormData();
            files.forEach((f) => form.append("files", f));
            await run(async () => {
              const r = await api<{ imported: string[] }>("/slicer/import", { method: "POST", body: form });
              inv("slicer-printers");
              return r;
            }, "Presets imported");
          }}
        />
      </label>
    </div>
  );
}

function Machines() {
  const kinds = useQuery({ queryKey: ["machine-kinds"], queryFn: () => api<MachineKind[]>("/machine-kinds") });
  const machines = useQuery({ queryKey: ["machines"], queryFn: () => api<Machine[]>("/machines"), refetchInterval: 5000 });
  const beds = useQuery({ queryKey: ["printers"], queryFn: () => api<Printer[]>("/printers") });
  const inv = useInvalidate();
  const run = useRun();
  const [form, setForm] = useState<MachineForm | null>(null);
  const kind = kinds.data?.find((k) => k.kind === form?.kind);
  type Found = { kind: string; serial: string; host: string; name: string; model: string; lan_mode: boolean; added: boolean };
  const [found, setFound] = useState<Found[] | null>(null);
  const [searching, setSearching] = useState(false);
  const findPrinters = async () => {
    setSearching(true);
    await run(async () => setFound(await api<Found[]>("/machines/discover", { method: "POST" })));
    setSearching(false);
  };

  const save = async () => {
    if (!form) return;
    // An empty secret on an existing printer keeps the stored one.
    const body = { ...form, secret: form.id && !form.secret ? null : form.secret };
    const ok = await run(() => api(form.id ? `/machines/${form.id}` : "/machines", { method: form.id ? "PATCH" : "POST", json: body }), "Printer saved");
    if (ok) {
      setForm(null);
      inv("machines");
    }
  };

  return (
    <section className="panel col" style={{ marginBottom: 16 }}>
      <div className="row">
        <h2>Connected printers</h2>
        <span className="spacer" />
        {!form && (
          <>
            <button className="small" disabled={searching} onClick={findPrinters}>
              {searching ? "Searching…" : "Find printers"}
            </button>
            <button className="small primary" onClick={() => setForm({ ...EMPTY_MACHINE, kind: kinds.data?.[0]?.kind ?? "" })}>
              Add printer
            </button>
          </>
        )}
      </div>
      {found && !form && (
        <div className="col" style={{ gap: 6 }}>
          {!found.length && (
            <p className="dim" style={{ margin: 0 }}>
              No printers answered. Check the printer is on the same network. The 3DVault container needs host networking to hear printer announcements; otherwise add the printer by IP address.
            </p>
          )}
          {found.map((p) => (
            <div key={p.serial} className="row" style={{ gap: 8 }}>
              <span>
                {p.name} <span className="dim">{[p.model, p.host, p.lan_mode ? null : "not in LAN mode"].filter(Boolean).join(" · ")}</span>
              </span>
              <span className="spacer" />
              {p.added ? (
                <span className="dim">Added</span>
              ) : (
                <button className="small" onClick={() => setForm({ ...EMPTY_MACHINE, name: p.name, kind: p.kind, host: p.host, serial: p.serial })}>
                  Set up
                </button>
              )}
            </div>
          ))}
        </div>
      )}
      <p className="dim" style={{ margin: 0 }}>Printers 3DVault can send prints to. Everyone signed in can print to them and see their status.</p>
      <SlicerProfiles />
      {!!machines.data?.length && (
        <table className="list">
          <tbody>
            {machines.data.map((m) => (
              <tr key={m.id}>
                <td>{m.name}</td>
                <td className="dim">{kinds.data?.find((k) => k.kind === m.kind)?.label ?? m.kind}</td>
                <td className="dim">{m.enabled ? m.status.state : "disabled"}</td>
                <td style={{ textAlign: "right", whiteSpace: "nowrap" }}>
                  <button className="small" onClick={() => setForm({ ...m, secret: "" })}>
                    Edit
                  </button>{" "}
                  <button
                    className="small danger"
                    onClick={() => window.confirm(`Remove ${m.name}? Its print history is deleted too.`) && run(() => api(`/machines/${m.id}`, { method: "DELETE" })).then(() => inv("machines"))}
                  >
                    Remove
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {form && (
        <div className="col" style={{ gap: 8, maxWidth: 460 }}>
          <label>
            Name
            <input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} placeholder="A1 mini" />
          </label>
          <label>
            Type
            <select value={form.kind} onChange={(e) => setForm({ ...form, kind: e.target.value })}>
              {kinds.data?.map((k) => (
                <option key={k.kind} value={k.kind}>
                  {k.label}
                </option>
              ))}
            </select>
          </label>
          {form.kind === "bambu" && (
            <p className="dim" style={{ margin: 0 }}>
              On the printer, turn on LAN Only mode and Developer Mode (Settings › Network on the A1, P1 and X1). The access code is shown on the same screen.
              Bambu Handy and Bambu cloud stop working with the printer while LAN Only mode is on.
            </p>
          )}
          {kind?.fields.map((f) => (
            <label key={f.key}>
              {f.label}
              {f.secret ? (
                <input
                  type="password"
                  autoComplete="off"
                  value={form.secret}
                  placeholder={form.has_secret ? "Unchanged" : ""}
                  onChange={(e) => setForm({ ...form, secret: e.target.value })}
                />
              ) : (
                <input value={form[f.key as "host" | "serial"]} onChange={(e) => setForm({ ...form, [f.key]: e.target.value })} />
              )}
            </label>
          ))}
          <label>
            Slicer profile
            <SlicerPrinterInput value={form.slicer_printer} onChange={(v) => setForm({ ...form, slicer_printer: v })} />
            <span className="faint" style={{ fontSize: 12 }}>The OrcaSlicer printer used when 3DVault slices for this printer.</span>
          </label>
          <label>
            Bed size
            <select value={form.printer_id ?? ""} onChange={(e) => setForm({ ...form, printer_id: e.target.value ? Number(e.target.value) : null })}>
              <option value="">Unknown</option>
              {beds.data?.map((b) => (
                <option key={b.id} value={b.id}>
                  {b.name}
                </option>
              ))}
            </select>
          </label>
          <label className="row" style={{ gap: 6 }}>
            <input type="checkbox" checked={form.enabled} onChange={(e) => setForm({ ...form, enabled: e.target.checked })} /> Enabled
          </label>
          <div className="row" style={{ gap: 8 }}>
            <button className="primary" disabled={!form.name || !form.kind} onClick={save}>
              Save
            </button>
            <button onClick={() => setForm(null)}>Cancel</button>
          </div>
        </div>
      )}
    </section>
  );
}

/* ---------------------------------------------------------------- printers */

function Printers() {
  const q = useQuery({ queryKey: ["printers"], queryFn: () => api<Printer[]>("/printers") });
  const inv = useInvalidate();
  const run = useRun();
  const [p, setP] = useState({ name: "", x: "", y: "", z: "" });
  const save = (row: Printer, patch: Partial<Printer>) => run(() => api(`/printers/${row.id}`, { method: "PATCH", json: { ...row, ...patch } })).then(() => inv("printers"));
  return (
    <section className="panel col">
      <h2>Bed sizes</h2>
      <p className="dim" style={{ margin: 0 }}>Build volumes in mm. Used by the “Fits printer” filter. Parts may be rotated to fit.</p>
      <table className="list">
        <thead>
          <tr>
            <th>Name</th>
            <th>X</th>
            <th>Y</th>
            <th>Z</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {q.data?.map((row) => (
            <tr key={row.id}>
              <td>
                <input defaultValue={row.name} onBlur={(e) => e.target.value !== row.name && save(row, { name: e.target.value })} />
              </td>
              {(["x", "y", "z"] as const).map((k) => (
                <td key={k} style={{ width: 90 }}>
                  <input inputMode="decimal" defaultValue={row[k]} onBlur={(e) => Number(e.target.value) !== row[k] && save(row, { [k]: Number(e.target.value) })} />
                </td>
              ))}
              <td style={{ textAlign: "right" }}>
                <button className="small danger" onClick={() => run(() => api(`/printers/${row.id}`, { method: "DELETE" })).then(() => inv("printers"))}>
                  Delete
                </button>
              </td>
            </tr>
          ))}
          <tr>
            <td>
              <input placeholder="New printer" value={p.name} onChange={(e) => setP({ ...p, name: e.target.value })} />
            </td>
            {(["x", "y", "z"] as const).map((k) => (
              <td key={k}>
                <input inputMode="decimal" placeholder={k.toUpperCase()} value={p[k]} onChange={(e) => setP({ ...p, [k]: e.target.value })} />
              </td>
            ))}
            <td style={{ textAlign: "right" }}>
              <button
                className="small primary"
                disabled={!p.name || !p.x || !p.y || !p.z}
                onClick={async () =>
                  (await run(() => api("/printers", { method: "POST", json: { name: p.name, x: +p.x, y: +p.y, z: +p.z } }))) && (setP({ name: "", x: "", y: "", z: "" }), inv("printers"))
                }
              >
                Add
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </section>
  );
}

/* ---------------------------------------------------------------- rules */

const FIELD_LABELS: Record<Rule["field"], string> = { any: "Name, file or link", filename: "File names", name: "Model name", source_url: "Source link" };

function Rules() {
  const q = useQuery({ queryKey: ["rules"], queryFn: () => api<Rule[]>("/rules") });
  const inv = useInvalidate();
  const run = useRun();
  const blank = { name: "", field: "any" as Rule["field"], pattern: "", add_tags: [] as string[], category_id: null as number | null, enabled: true };
  const [draft, setDraft] = useState(blank);
  return (
    <div className="col" style={{ gap: 16 }}>
      <section className="panel col">
        <h2>New rule</h2>
        <p className="dim" style={{ margin: 0 }}>
          When an imported model’s text contains the pattern, add the tags and set the category if none is set. Example: file names contain “gridfinity” → tag
          gridfinity, category Organisers.
        </p>
        <div className="row wrap">
          <select value={draft.field} onChange={(e) => setDraft({ ...draft, field: e.target.value as Rule["field"] })} style={{ width: 180 }}>
            {Object.entries(FIELD_LABELS).map(([k, v]) => (
              <option key={k} value={k}>
                {v}
              </option>
            ))}
          </select>
          <span className="dim">contains</span>
          <input placeholder="pattern" value={draft.pattern} onChange={(e) => setDraft({ ...draft, pattern: e.target.value, name: draft.name || e.target.value })} style={{ width: 180 }} />
        </div>
        <div className="row wrap">
          <div className="grow" style={{ minWidth: 220 }}>
            <TagInput value={draft.add_tags} onChange={(add_tags) => setDraft({ ...draft, add_tags })} placeholder="Tags to add…" />
          </div>
          <div style={{ width: 220 }}>
            <CategorySelect value={draft.category_id} onChange={(category_id) => setDraft({ ...draft, category_id })} noneLabel="Don't set category" />
          </div>
          <button
            className="primary"
            disabled={!draft.pattern || (!draft.add_tags.length && !draft.category_id)}
            onClick={async () => (await run(() => api("/rules", { method: "POST", json: draft }))) && (setDraft(blank), inv("rules"))}
          >
            Add rule
          </button>
        </div>
      </section>
      <section className="panel col">
        <div className="row">
          <h2>Rules</h2>
          <span className="spacer" />
          <button onClick={() => run(() => api("/rules/apply?untriaged_only=true", { method: "POST" }), "Applying rules to untriaged models…")}>Run on untriaged</button>
          <button onClick={() => run(() => api("/rules/apply?untriaged_only=false", { method: "POST" }), "Applying rules to the whole library…")}>Run on everything</button>
        </div>
        {(q.data ?? []).map((r) => (
          <div key={r.id} className="row wrap" style={{ borderTop: "1px solid var(--border)", paddingTop: 10 }}>
            <input
              type="checkbox"
              checked={r.enabled}
              onChange={(e) => run(() => api(`/rules/${r.id}`, { method: "PATCH", json: { ...r, enabled: e.target.checked } })).then(() => inv("rules"))}
            />
            <span className="grow">
              {FIELD_LABELS[r.field]} contains <code>{r.pattern}</code> →{" "}
              {r.add_tags.map((t) => (
                <span key={t} className="chip accent" style={{ marginRight: 4 }}>
                  {t}
                </span>
              ))}
              {r.category_id && <CategoryName id={r.category_id} />}
            </span>
            <button className="small danger" onClick={() => run(() => api(`/rules/${r.id}`, { method: "DELETE" })).then(() => inv("rules"))}>
              Delete
            </button>
          </div>
        ))}
        {!q.data?.length && <p className="faint">No rules yet.</p>}
      </section>
    </div>
  );
}

function CategoryName({ id }: { id: number }) {
  const { data: cats = [] } = useCategories();
  const c = cats.find((x) => x.id === id);
  return <span className="chip">{c ? c.name : "?"}</span>;
}

/* ---------------------------------------------------------------- collections */

function Collections() {
  const q = useQuery({ queryKey: ["collections"], queryFn: () => api<Collection[]>("/collections") });
  const inv = useInvalidate();
  const run = useRun();
  const user = useUser();
  const [name, setName] = useState("");
  return (
    <section className="panel col">
      <p className="dim" style={{ margin: 0 }}>
        Manual collections hold models you add. Smart collections are saved filters: set filters in the library, then press Save.
      </p>
      <div className="row">
        <input placeholder="New manual collection" value={name} onChange={(e) => setName(e.target.value)} style={{ maxWidth: 260 }} />
        <button disabled={!name} onClick={async () => (await run(() => api("/collections", { method: "POST", json: { name, kind: "manual" } }))) && (setName(""), inv("collections"))}>
          Create
        </button>
      </div>
      <table className="list">
        <thead>
          <tr>
            <th>Name</th>
            <th>Type</th>
            <th>Shared</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {q.data?.map((c) => {
            const mine = c.owner_id === user.id || user.role === "admin";
            return (
              <tr key={c.id}>
                <td>
                  <input
                    defaultValue={c.name}
                    disabled={!mine}
                    onBlur={(e) => e.target.value !== c.name && run(() => api(`/collections/${c.id}`, { method: "PATCH", json: { ...c, name: e.target.value } })).then(() => inv("collections"))}
                  />
                </td>
                <td className="dim">{c.kind === "smart" ? "Smart" : `Manual · ${c.count}`}</td>
                <td>
                  <input
                    type="checkbox"
                    checked={c.shared}
                    disabled={!mine}
                    onChange={(e) => run(() => api(`/collections/${c.id}`, { method: "PATCH", json: { ...c, shared: e.target.checked } })).then(() => inv("collections"))}
                  />
                </td>
                <td style={{ textAlign: "right" }}>
                  <Link className="btn small" to={`/?collection_id=${c.id}`}>
                    Open
                  </Link>{" "}
                  {mine && (
                    <button className="small danger" onClick={() => run(() => api(`/collections/${c.id}`, { method: "DELETE" })).then(() => inv("collections"))}>
                      Delete
                    </button>
                  )}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </section>
  );
}

/* ---------------------------------------------------------------- users */

function Users() {
  const me = useUser();
  const q = useQuery({ queryKey: ["users"], queryFn: () => api<User[]>("/users") });
  const inv = useInvalidate();
  const run = useRun();
  const [u, setU] = useState({ username: "", display_name: "", password: "", role: "member" });
  return (
    <div className="col" style={{ gap: 16 }}>
      <section className="panel col">
        <h2>Add a person</h2>
        <p className="dim" style={{ margin: 0 }}>Members can upload, tag and edit anything, and delete only what they uploaded. Admins manage users and settings.</p>
        <div className="row wrap">
          <input placeholder="Username" value={u.username} onChange={(e) => setU({ ...u, username: e.target.value })} style={{ width: 160 }} />
          <input placeholder="Display name" value={u.display_name} onChange={(e) => setU({ ...u, display_name: e.target.value })} style={{ width: 180 }} />
          <input placeholder="Password (8+)" type="password" value={u.password} onChange={(e) => setU({ ...u, password: e.target.value })} style={{ width: 180 }} autoComplete="new-password" />
          <select value={u.role} onChange={(e) => setU({ ...u, role: e.target.value })} style={{ width: 120 }}>
            <option value="member">Member</option>
            <option value="admin">Admin</option>
          </select>
          <button
            className="primary"
            disabled={!u.username || u.password.length < 8}
            onClick={async () => (await run(() => api("/users", { method: "POST", json: u }), `Added ${u.username}`)) && (setU({ username: "", display_name: "", password: "", role: "member" }), inv("users"))}
          >
            Add
          </button>
        </div>
      </section>
      <section className="panel">
        <table className="list">
          <thead>
            <tr>
              <th>Username</th>
              <th>Display name</th>
              <th>Role</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {q.data?.map((row) => (
              <tr key={row.id}>
                <td>{row.username}</td>
                <td>
                  <input
                    defaultValue={row.display_name}
                    onBlur={(e) => e.target.value !== row.display_name && run(() => api(`/users/${row.id}`, { method: "PATCH", json: { display_name: e.target.value } })).then(() => inv("users"))}
                  />
                </td>
                <td style={{ width: 130 }}>
                  <select value={row.role} onChange={(e) => run(() => api(`/users/${row.id}`, { method: "PATCH", json: { role: e.target.value } })).then(() => inv("users"))}>
                    <option value="member">Member</option>
                    <option value="admin">Admin</option>
                  </select>
                </td>
                <td style={{ textAlign: "right", whiteSpace: "nowrap" }}>
                  <button
                    className="small"
                    onClick={() => {
                      const pw = window.prompt(`New password for ${row.username} (8+ characters). This signs them out everywhere.`);
                      if (pw) run(() => api(`/users/${row.id}`, { method: "PATCH", json: { password: pw } }), "Password reset");
                    }}
                  >
                    Reset password
                  </button>{" "}
                  {row.id !== me.id && (
                    <button
                      className="small danger"
                      onClick={() => window.confirm(`Delete ${row.username}? Their models stay in the library.`) && run(() => api(`/users/${row.id}`, { method: "DELETE" })).then(() => inv("users"))}
                    >
                      Delete
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>
    </div>
  );
}

/* ---------------------------------------------------------------- system */

type JobSummary = { counts: Record<string, number>; recent_errors: { id: number; kind: string; payload: Record<string, unknown>; error: string }[] };

function System() {
  const run = useRun();
  const settings = useQuery({ queryKey: ["settings"], queryFn: () => api<Record<string, string>>("/settings") });
  const jobs = useQuery({ queryKey: ["jobs"], queryFn: () => api<JobSummary>("/jobs/summary"), refetchInterval: 5000 });
  const stats = useQuery({ queryKey: ["stats"], queryFn: () => api<{ models: number; untriaged: number; trash: number; tags: number }>("/stats") });
  const [token, setToken] = useState<string | null>(null);
  return (
    <div className="col" style={{ gap: 16 }}>
      <section className="panel col">
        <h2>Library</h2>
        <div className="row wrap" style={{ gap: 18 }}>
          <span>
            <strong>{stats.data?.models ?? "…"}</strong> <span className="dim">models</span>
          </span>
          <span>
            <strong>{stats.data?.untriaged ?? "…"}</strong> <span className="dim">untriaged</span>
          </span>
          <span>
            <strong>{stats.data?.tags ?? "…"}</strong> <span className="dim">tags in use</span>
          </span>
          <Link to="/trash" className="link">
            {stats.data?.trash ?? 0} in trash
          </Link>
        </div>
        <div className="row">
          <button onClick={() => run(() => api("/admin/rescan", { method: "POST" }), "Rescan queued")}>
            <Icon name="refresh" /> Rescan library folder
          </button>
          <span className="faint" style={{ fontSize: 12 }}>
            Picks up files added or removed directly on the NAS, and rebuilds models from model.json sidecars.
          </span>
        </div>
      </section>

      <section className="panel col">
        <h2>Background jobs</h2>
        <div className="row wrap" style={{ gap: 14 }}>
          {["queued", "running", "done", "error"].map((s) => (
            <span key={s}>
              <strong>{jobs.data?.counts[s] ?? 0}</strong> <span className="dim">{s}</span>
            </span>
          ))}
        </div>
        {jobs.data?.recent_errors.map((j) => (
          <div key={j.id} className="row" style={{ fontSize: 12 }}>
            <span className="chip danger">{j.kind}</span>
            <code className="dim ellipsis grow" title={j.error}>
              {j.error}
            </code>
          </div>
        ))}
      </section>

      <section className="panel col" style={{ maxWidth: 560 }}>
        <h2>Integrations</h2>
        <label className="field">
          Thingiverse app token (optional, for importing details from Thingiverse links)
          <input
            type="password"
            placeholder={settings.data?.thingiverse_token ? "••••••••  (set)" : "Paste token"}
            value={token ?? ""}
            onChange={(e) => setToken(e.target.value)}
          />
        </label>
        <div className="row">
          <button className="primary" disabled={token === null} onClick={() => run(() => api("/settings", { method: "PUT", json: { thingiverse_token: token } }), "Saved").then(() => setToken(null))}>
            Save
          </button>
          <span className="faint" style={{ fontSize: 12 }}>
            Printables works without a token. MakerWorld is best effort.
          </span>
        </div>
      </section>
    </div>
  );
}
