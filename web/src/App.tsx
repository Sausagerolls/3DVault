import { createContext, useContext, useEffect, useState } from "react";
import { NavLink, Navigate, Route, Routes, useLocation, useNavigate, useSearchParams } from "react-router-dom";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { api, type User } from "./api";
import { Icon, ToastProvider } from "./components/ui";
import Library from "./pages/Library";
import ModelPage from "./pages/ModelPage";
import Upload, { setPendingDrop } from "./pages/Upload";
import Settings from "./pages/Settings";
import Login from "./pages/Login";
import { collectDropped } from "./pages/drop";

const UserCtx = createContext<User | null>(null);
export const useUser = () => useContext(UserCtx)!;

export default function App() {
  const qc = useQueryClient();
  const status = useQuery({ queryKey: ["auth-status"], queryFn: () => api<{ needs_setup: boolean }>("/auth/status") });
  const me = useQuery({
    queryKey: ["me"],
    queryFn: () => api<User>("/auth/me"),
    retry: false,
    enabled: status.data?.needs_setup === false,
  });

  useEffect(() => {
    const onUnauth = () => qc.setQueryData(["me"], null);
    window.addEventListener("vault:unauthorised", onUnauth);
    return () => window.removeEventListener("vault:unauthorised", onUnauth);
  }, [qc]);

  if (status.isLoading || (status.data && !status.data.needs_setup && me.isLoading)) return null;
  if (status.error) return <div className="auth-wrap"><div className="error-box">Cannot reach the 3DVault server.</div></div>;
  if (status.data?.needs_setup || !me.data)
    return (
      <ToastProvider>
        <Login setup={!!status.data?.needs_setup} />
      </ToastProvider>
    );

  return (
    <UserCtx.Provider value={me.data}>
      <ToastProvider>
        <Shell />
      </ToastProvider>
    </UserCtx.Provider>
  );
}

function Shell() {
  const user = useUser();
  const qc = useQueryClient();
  const navigate = useNavigate();
  const location = useLocation();
  const [params, setParams] = useSearchParams();
  const [dragging, setDragging] = useState(false);
  const stats = useQuery({
    queryKey: ["stats"],
    queryFn: () => api<{ models: number; untriaged: number; trash: number }>("/stats"),
    refetchInterval: 30_000,
  });
  const [search, setSearch] = useState(params.get("q") ?? "");

  useEffect(() => setSearch(params.get("q") ?? ""), [params]);

  // Drop files anywhere in the app to start an upload.
  useEffect(() => {
    let depth = 0;
    const hasFiles = (e: DragEvent) => e.dataTransfer?.types.includes("Files");
    const enter = (e: DragEvent) => {
      if (!hasFiles(e) || location.pathname === "/upload") return;
      depth++;
      setDragging(true);
    };
    const leave = () => {
      depth = Math.max(0, depth - 1);
      if (!depth) setDragging(false);
    };
    const over = (e: DragEvent) => hasFiles(e) && e.preventDefault();
    const drop = async (e: DragEvent) => {
      if (!hasFiles(e) || location.pathname === "/upload") return;
      e.preventDefault();
      depth = 0;
      setDragging(false);
      setPendingDrop(await collectDropped(e.dataTransfer!));
      navigate("/upload");
    };
    window.addEventListener("dragenter", enter);
    window.addEventListener("dragleave", leave);
    window.addEventListener("dragover", over);
    window.addEventListener("drop", drop);
    return () => {
      window.removeEventListener("dragenter", enter);
      window.removeEventListener("dragleave", leave);
      window.removeEventListener("dragover", over);
      window.removeEventListener("drop", drop);
    };
  }, [location.pathname, navigate]);

  const submitSearch = (q: string) => {
    if (location.pathname !== "/" && location.pathname !== "/untriaged") {
      navigate(q ? `/?q=${encodeURIComponent(q)}` : "/");
      return;
    }
    const next = new URLSearchParams(params);
    if (q) next.set("q", q);
    else next.delete("q");
    setParams(next, { replace: true });
  };

  const logout = async () => {
    await api("/auth/logout", { method: "POST" });
    qc.setQueryData(["me"], null);
  };

  return (
    <div className="shell">
      <header className="topbar">
        <NavLink to="/" className="brand">
          <img src="/favicon.svg" alt="" />
          3DVault
        </NavLink>
        <div className="search">
          <Icon name="search" />
          <input
            placeholder="Search models, tags, files…"
            value={search}
            onChange={(e) => {
              setSearch(e.target.value);
              submitSearch(e.target.value);
            }}
            onKeyDown={(e) => e.key === "Escape" && (setSearch(""), submitSearch(""))}
          />
        </div>
        <nav>
          <NavLink to="/" end>
            <Icon name="grid" />
            <span className="label">Library</span>
          </NavLink>
          <NavLink to="/untriaged">
            <Icon name="inbox" />
            <span className="label">Untriaged</span>
            {!!stats.data?.untriaged && <span className="badge">{stats.data.untriaged}</span>}
          </NavLink>
          <NavLink to="/upload">
            <Icon name="upload" />
            <span className="label">Upload</span>
          </NavLink>
          <NavLink to="/settings">
            <Icon name="settings" />
            <span className="label">Settings</span>
          </NavLink>
        </nav>
        <span className="spacer" />
        <span className="dim ellipsis" title={user.username}>
          {user.display_name}
        </span>
        <button className="ghost icon" onClick={logout} title="Sign out">
          <Icon name="logout" />
        </button>
      </header>
      <div className="main">
        <Routes>
          <Route path="/" element={<Library />} />
          <Route path="/untriaged" element={<Library preset={{ untriaged: "true" }} title="Untriaged" />} />
          <Route path="/trash" element={<Library preset={{ trashed: "true" }} title="Trash" />} />
          <Route path="/models/:id" element={<ModelPage />} />
          <Route path="/upload" element={<Upload />} />
          <Route path="/settings/*" element={<Settings />} />
          <Route path="*" element={<Navigate to="/" />} />
        </Routes>
      </div>
      {dragging && <div className="global-drop">Drop to upload</div>}
    </div>
  );
}
