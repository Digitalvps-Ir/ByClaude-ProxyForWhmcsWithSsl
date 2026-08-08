#!/usr/bin/env python3
"""
dashboard.py — a small, self-contained HTTPS admin panel for the WHMCS SSL
proxy stack. It edits the same state file as gostctl.py, so the UI, the CLI
and the running gost service always agree.

Features
  * manage proxy users (add / delete / reset password / enable-disable)
  * change listener ports (https / socks / http / tunnel)
  * configure the tunnel to the exit node (entry role)
  * one-click "Apply" -> regenerate gost config and restart the service
  * live status: gost active?, certificate expiry, ready-to-paste WHMCS settings

Security
  * served over TLS using the same Let's Encrypt certificate as the proxy
  * HTTP Basic auth against a PBKDF2 admin password kept in the state file
  * per-process CSRF token required on every mutating request
  * still: restrict the dashboard port with a firewall to your own IP

Stdlib only. Run:  python3 dashboard.py   (reads /etc/gost/state.json)
"""

import base64
import html
import os
import secrets
import ssl
import subprocess
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import gostctl

CSRF = secrets.token_urlsafe(24)
LISTEN_ADDR = os.environ.get("DASH_ADDR", "0.0.0.0")


# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------
def page(state, notice=""):
    role = state.get("role", "entry")
    domain = state.get("domain", "")
    active = gostctl.service_active() or "unknown"
    exp = gostctl.cert_expiry(state) or "—"
    badge = "#16a34a" if active == "active" else "#dc2626"

    eps = "".join(
        f"<tr><td>{html.escape(l)}</td><td><code>{html.escape(v)}</code></td></tr>"
        for l, v in gostctl.endpoints(state)
    )

    rows = ""
    for u in state.get("users", []):
        en = u.get("enabled", True)
        rows += f"""
        <tr>
          <td><b>{html.escape(u['username'])}</b></td>
          <td><code>{html.escape(u['password'])}</code></td>
          <td>{'✅' if en else '⛔'}</td>
          <td class="actions">
            <form method="post" action="/users/toggle">{hidden('username', u['username'])}<button>{'Disable' if en else 'Enable'}</button></form>
            <form method="post" action="/users/passwd">{hidden('username', u['username'])}<button>New password</button></form>
            <form method="post" action="/users/del" onsubmit="return confirm('Delete {html.escape(u['username'])}?')">{hidden('username', u['username'])}<button class="danger">Delete</button></form>
          </td>
        </tr>"""

    ports = state.get("ports", {})
    port_fields = ""
    order = ["https", "socks", "http", "dashboard"]
    if role == "exit":
        order = ["tunnel", "dashboard"]
    for name in order:
        port_fields += f"""
          <label>{name}<input name="{name}" type="number" value="{ports.get(name,0)}"></label>"""

    exit_block = ""
    if role == "entry":
        ex = state.get("exit", {})
        exit_block = f"""
      <section>
        <h2>🔐 Tunnel to exit node (foreign server)</h2>
        <p class="muted">The encrypted TLS relay tunnel that carries traffic abroad.</p>
        <form method="post" action="/exit" class="grid">
          {csrf_field()}
          <label>Exit host (FQDN)<input name="host" value="{html.escape(ex.get('host',''))}"></label>
          <label>Exit port<input name="port" type="number" value="{ex.get('port',8443)}"></label>
          <label>Tunnel user<input name="user" value="{html.escape(ex.get('user',''))}"></label>
          <label>Tunnel password<input name="password" value="{html.escape(ex.get('password',''))}"></label>
          <label class="chk"><input type="checkbox" name="secure" {'checked' if ex.get('secure',True) else ''}> verify exit certificate</label>
          <button class="primary">Save tunnel</button>
        </form>
      </section>"""

    whmcs = ""
    if role == "entry" and ports.get("https"):
        first = next((u for u in state.get("users", []) if u.get("enabled", True)), None)
        uu = first["username"] if first else "USER"
        pp = first["password"] if first else "PASS"
        whmcs = f"""
      <section>
        <h2>🧩 WHMCS / module settings</h2>
        <table class="kv">
          <tr><td>Proxy type</td><td><code>HTTPS</code> (CURLPROXY_HTTPS)</td></tr>
          <tr><td>Proxy host</td><td><code>{html.escape(domain)}</code></td></tr>
          <tr><td>Proxy port</td><td><code>{ports.get('https')}</code></td></tr>
          <tr><td>Username</td><td><code>{html.escape(uu)}</code></td></tr>
          <tr><td>Password</td><td><code>{html.escape(pp)}</code></td></tr>
          <tr><td>cURL proxy URL</td><td><code>https://{html.escape(uu)}:{html.escape(pp)}@{html.escape(domain)}:{ports.get('https')}</code></td></tr>
        </table>
      </section>"""

    notice_html = f'<div class="notice">{html.escape(notice)}</div>' if notice else ""

    return f"""<!doctype html>
<html lang="fa" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>WHMCS Proxy Panel — {html.escape(domain)}</title>
<style>
  :root {{ color-scheme: light dark; }}
  * {{ box-sizing: border-box; }}
  body {{ font-family: system-ui, "Segoe UI", Tahoma, sans-serif; margin:0; background:#0b1020; color:#e6e9f0; }}
  header {{ background:#111a33; padding:18px 22px; border-bottom:1px solid #223; display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:10px;}}
  header h1 {{ font-size:18px; margin:0; }}
  .badge {{ padding:4px 10px; border-radius:20px; color:#fff; font-size:12px; background:{badge}; }}
  main {{ max-width:960px; margin:22px auto; padding:0 16px; }}
  section {{ background:#131c36; border:1px solid #24304f; border-radius:12px; padding:18px; margin-bottom:18px; }}
  h2 {{ font-size:16px; margin:0 0 10px; }}
  table {{ width:100%; border-collapse:collapse; }}
  td, th {{ padding:8px 10px; border-bottom:1px solid #24304f; text-align:right; vertical-align:middle; }}
  code {{ background:#0b1020; padding:2px 6px; border-radius:6px; direction:ltr; display:inline-block; }}
  .actions {{ display:flex; gap:6px; flex-wrap:wrap; }}
  form {{ display:inline; }}
  button {{ background:#2a3a63; color:#e6e9f0; border:1px solid #3a4d80; border-radius:8px; padding:7px 12px; cursor:pointer; font-size:13px; }}
  button:hover {{ background:#34477a; }}
  button.primary, button.apply {{ background:#2563eb; border-color:#2563eb; }}
  button.danger {{ background:#7f1d1d; border-color:#991b1b; }}
  .grid {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(180px,1fr)); gap:12px; align-items:end; }}
  label {{ display:flex; flex-direction:column; gap:6px; font-size:13px; color:#aab3c9; }}
  label.chk {{ flex-direction:row; align-items:center; gap:8px; }}
  input {{ background:#0b1020; border:1px solid #33406a; color:#e6e9f0; border-radius:8px; padding:9px; font-size:14px; direction:ltr; }}
  .muted {{ color:#8b93a7; font-size:13px; margin:2px 0 12px; }}
  .notice {{ background:#14361f; border:1px solid #1f5a33; color:#c7f9d8; padding:10px 14px; border-radius:10px; margin-bottom:16px; }}
  .kv td:first-child {{ color:#aab3c9; width:180px; }}
  .apply-bar {{ position:sticky; bottom:0; background:#0b1020cc; backdrop-filter:blur(6px); padding:12px; text-align:center; border-top:1px solid #24304f;}}
</style></head>
<body>
<header>
  <h1>🛡️ WHMCS Proxy Panel <span class="muted">({html.escape(role)} · {html.escape(domain)})</span></h1>
  <div>gost: <span class="badge">{html.escape(active)}</span></div>
</header>
<main>
  {notice_html}
  <section>
    <h2>📊 Status</h2>
    <table class="kv">
      <tr><td>Role</td><td><code>{html.escape(role)}</code></td></tr>
      <tr><td>Domain</td><td><code>{html.escape(domain)}</code></td></tr>
      <tr><td>Certificate expires</td><td><code>{html.escape(exp)}</code> <span class="muted">(auto-renews)</span></td></tr>
    </table>
    <h2 style="margin-top:16px">🔌 Endpoints</h2>
    <table>{eps or '<tr><td>—</td></tr>'}</table>
  </section>
  {whmcs}
  <section>
    <h2>👤 Proxy users</h2>
    <table>
      <tr><th>User</th><th>Password</th><th>On</th><th>Actions</th></tr>
      {rows or '<tr><td colspan=4 class=muted>No users yet</td></tr>'}
    </table>
    <form method="post" action="/users/add" class="grid" style="margin-top:14px">
      {csrf_field()}
      <label>New username<input name="username" required></label>
      <label>Password <span class="muted">(blank = random)</span><input name="password"></label>
      <button class="primary">Add user</button>
    </form>
  </section>
  <section>
    <h2>🔧 Ports</h2>
    <form method="post" action="/ports" class="grid">
      {csrf_field()}
      {port_fields}
      <button class="primary">Save ports</button>
    </form>
    <p class="muted">Changing ports rewrites the gost config; click Apply to restart with the new values.</p>
  </section>
  {exit_block}
  <section>
    <h2>🔑 Admin password</h2>
    <form method="post" action="/admin/passwd" class="grid">
      {csrf_field()}
      <label>New admin password<input name="password" required></label>
      <button>Change</button>
    </form>
  </section>
  <div class="apply-bar">
    <form method="post" action="/apply">{csrf_field()}<button class="apply">💾 Apply &amp; restart gost</button></form>
  </div>
</main>
</body></html>"""


def hidden(name, value):
    return csrf_field() + f'<input type="hidden" name="{html.escape(name)}" value="{html.escape(str(value))}">'


def csrf_field():
    return f'<input type="hidden" name="csrf" value="{CSRF}">'


# --------------------------------------------------------------------------
# HTTP handler
# --------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "whmcs-proxy-panel"

    def _auth_ok(self):
        state = gostctl.load_state()
        admin = state.get("admin", {})
        hdr = self.headers.get("Authorization", "")
        if not hdr.startswith("Basic "):
            return False
        try:
            raw = base64.b64decode(hdr[6:]).decode()
            user, _, pw = raw.partition(":")
        except Exception:
            return False
        return (user == admin.get("username")
                and gostctl.verify_password(pw, admin.get("salt", ""), admin.get("hash", "")))

    def _require_auth(self):
        if self._auth_ok():
            return True
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="WHMCS Proxy Panel"')
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write("authentication required\n".encode())
        return False

    def _redirect(self, notice=""):
        loc = "/"
        if notice:
            loc += "?m=" + urllib.parse.quote(notice)
        self.send_response(303)
        self.send_header("Location", loc)
        self.end_headers()

    def _html(self, body, code=200):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self._require_auth():
            return
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path not in ("/", ""):
            self._html("not found", 404)
            return
        q = urllib.parse.parse_qs(parsed.query)
        notice = (q.get("m", [""])[0])
        self._html(page(gostctl.load_state(), notice))

    def _read_form(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode()
        return {k: v[0] for k, v in urllib.parse.parse_qs(body).items()}

    def do_POST(self):
        if not self._require_auth():
            return
        form = self._read_form()
        if form.get("csrf") != CSRF:
            self._html("bad csrf token", 403)
            return
        path = urllib.parse.urlparse(self.path).path
        state = gostctl.load_state()
        try:
            notice = self._dispatch(path, form, state)
        except Exception as exc:  # keep the panel alive on bad input
            self._redirect(f"error: {exc}")
            return
        self._redirect(notice)

    def _dispatch(self, path, form, state):
        if path == "/users/add":
            name = form.get("username", "").strip()
            if not name:
                return "username required"
            if any(u["username"] == name for u in state["users"]):
                return f"user {name} already exists"
            pw = form.get("password", "").strip() or gostctl.gen_secret(18)
            state["users"].append({"username": name, "password": pw, "enabled": True})
            gostctl.save_state(state)
            return f"added user {name}"
        if path == "/users/del":
            name = form.get("username", "")
            state["users"] = [u for u in state["users"] if u["username"] != name]
            gostctl.save_state(state)
            return f"deleted {name}"
        if path == "/users/passwd":
            name = form.get("username", "")
            pw = gostctl.gen_secret(18)
            for u in state["users"]:
                if u["username"] == name:
                    u["password"] = pw
            gostctl.save_state(state)
            return f"new password for {name}: {pw}"
        if path == "/users/toggle":
            name = form.get("username", "")
            for u in state["users"]:
                if u["username"] == name:
                    u["enabled"] = not u.get("enabled", True)
            gostctl.save_state(state)
            return f"toggled {name}"
        if path == "/ports":
            for name in ("https", "socks", "http", "tunnel", "dashboard"):
                if name in form:
                    try:
                        state["ports"][name] = int(form[name])
                    except ValueError:
                        pass
            gostctl.save_state(state)
            return "ports saved (click Apply)"
        if path == "/exit":
            ex = state.setdefault("exit", {})
            ex["host"] = form.get("host", "").strip()
            ex["port"] = int(form.get("port", 8443) or 8443)
            ex["user"] = form.get("user", "").strip()
            ex["password"] = form.get("password", "").strip()
            ex["secure"] = form.get("secure") == "on"
            gostctl.save_state(state)
            return "tunnel settings saved (click Apply)"
        if path == "/admin/passwd":
            pw = form.get("password", "").strip()
            if len(pw) < 6:
                return "admin password too short"
            salt, h = gostctl.hash_password(pw)
            state["admin"]["salt"] = salt
            state["admin"]["hash"] = h
            gostctl.save_state(state)
            return "admin password changed"
        if path == "/apply":
            gostctl.write_config(state)
            ok, msg = gostctl.reload_service()
            return msg
        return "unknown action"

    def log_message(self, fmt, *args):  # quieter logs
        return


class TLSServer(ThreadingHTTPServer):
    """Wrap each accepted connection in TLS (robust across Python versions —
    more reliable than wrapping the listening socket in place)."""
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, handler, ssl_ctx):
        self.ssl_ctx = ssl_ctx
        super().__init__(addr, handler)

    def get_request(self):
        sock, addr = self.socket.accept()
        if self.ssl_ctx is not None:
            sock = self.ssl_ctx.wrap_socket(sock, server_side=True)
        return sock, addr

    def handle_error(self, request, client_address):
        # swallow TLS handshake noise (scanners, plain-HTTP probes)
        pass


def main():
    state = gostctl.load_state()
    port = int(state.get("ports", {}).get("dashboard", 9443))
    cert, key = gostctl.cert_paths(state)
    ctx = None
    scheme = "http (no cert found!)"
    if cert and os.path.exists(cert) and key and os.path.exists(key):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(cert, key)
        scheme = "https"
    httpd = TLSServer((LISTEN_ADDR, port), Handler, ctx)
    print(f"dashboard on {scheme}://{LISTEN_ADDR}:{port}  (state: {gostctl.STATE_PATH})", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
