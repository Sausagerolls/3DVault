import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { api } from "../api";

export default function Login({ setup }: { setup: boolean }) {
  const qc = useQueryClient();
  const [username, setUsername] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError("");
    try {
      if (setup) await api("/auth/setup", { method: "POST", json: { username, display_name: displayName, password } });
      else await api("/auth/login", { method: "POST", json: { username, password } });
      await qc.invalidateQueries();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="auth-wrap">
      <form className="auth-card card" onSubmit={submit}>
        <div className="brand" style={{ fontSize: 20 }}>
          <img src="/favicon.svg" alt="" style={{ width: 28, height: 28 }} />
          3DVault
        </div>
        {setup && <p className="dim" style={{ margin: 0 }}>Create the admin account to get started.</p>}
        <label className="field">
          Username
          <input autoFocus autoComplete="username" value={username} onChange={(e) => setUsername(e.target.value)} required />
        </label>
        {setup && (
          <label className="field">
            Display name
            <input value={displayName} onChange={(e) => setDisplayName(e.target.value)} placeholder={username} />
          </label>
        )}
        <label className="field">
          Password
          <input
            type="password"
            autoComplete={setup ? "new-password" : "current-password"}
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            minLength={setup ? 8 : undefined}
            required
          />
        </label>
        {error && <div className="error-box">{error}</div>}
        <button className="primary" disabled={busy}>
          {setup ? "Create admin account" : "Sign in"}
        </button>
      </form>
    </div>
  );
}
