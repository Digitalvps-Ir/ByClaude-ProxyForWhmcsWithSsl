#!/usr/bin/env python3
"""
gostctl.py — single source of truth for the WHMCS SSL proxy stack.

It keeps a small JSON "state" file describing this server's role, ports,
proxy users and (for the Iran entry node) the encrypted tunnel to the
foreign exit node. From that state it renders a gost v3 configuration and
reloads the gost service.

The same state file is edited by the web dashboard (dashboard.py) and by the
installer (setup.sh), so config, CLI and UI never drift apart.

Stdlib only — no pip packages required (works on a fresh Ubuntu/Debian box).

Roles
-----
  exit   : foreign server (e.g. 83.245.45.6). Terminates the TLS relay
           tunnel and reaches the real internet (Binance BSC RPC, etc.).
  entry  : Iran server (e.g. 109.122.244.5). Exposes the SOCKS5 + HTTPS
           proxies that WHMCS connects to, and forwards everything through
           the tunnel to the exit node. This is the IP/host you enter in
           WHMCS, and it carries a *valid* Let's Encrypt certificate.
"""

import argparse
import hashlib
import json
import os
import secrets
import string
import subprocess
import sys

STATE_PATH = os.environ.get("GOST_STATE", "/etc/gost/state.json")
CONFIG_PATH = os.environ.get("GOST_CONFIG", "/etc/gost/config.json")
LE_LIVE = os.environ.get("GOST_LE_LIVE", "/etc/letsencrypt/live")
GOST_SERVICE = os.environ.get("GOST_SERVICE", "gost")


# --------------------------------------------------------------------------
# state helpers
# --------------------------------------------------------------------------
def default_state(role="entry", domain=""):
    return {
        "role": role,
        "domain": domain,
        "cert": {
            # explicit cert/key paths; empty => derive from Let's Encrypt live dir
            "certFile": "",
            "keyFile": "",
        },
        "ports": {
            "https": 443,   # HTTPS forward proxy (TLS, valid cert) — WHMCS uses this
            "socks": 1080,  # SOCKS5 (auth)
            "http": 8080,   # plain HTTP proxy (optional, 0 = disabled)
            "tunnel": 8443,  # exit only: TLS relay tunnel listener
            "dashboard": 9443,  # admin web UI (TLS)
        },
        # tunnel: how the entry node reaches the exit node
        "exit": {
            "host": "",     # foreign server FQDN (must match its cert)
            "port": 8443,
            "user": "",
            "password": "",
            "secure": True,  # verify the exit's certificate (recommended)
        },
        # proxy users WHMCS / clients authenticate with (entry role) OR
        # tunnel users the entry node authenticates with (exit role)
        "users": [],
        # dashboard admin login
        "admin": {
            "username": "admin",
            "salt": "",
            "hash": "",
        },
    }


def load_state():
    if not os.path.exists(STATE_PATH):
        raise SystemExit(f"state file not found: {STATE_PATH} (run: gostctl.py init ...)")
    with open(STATE_PATH) as fh:
        return json.load(fh)


def save_state(state):
    os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh, indent=2)
    os.replace(tmp, STATE_PATH)
    try:
        os.chmod(STATE_PATH, 0o600)
    except PermissionError:
        pass


def gen_secret(n=20):
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(n))


def hash_password(password, salt=None):
    if salt is None:
        salt = secrets.token_hex(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 200_000)
    return salt, dk.hex()


def verify_password(password, salt, expected_hex):
    if not salt or not expected_hex:
        return False
    _, got = hash_password(password, salt)
    return secrets.compare_digest(got, expected_hex)


# --------------------------------------------------------------------------
# certificate path resolution
# --------------------------------------------------------------------------
def cert_paths(state):
    cert = state.get("cert", {})
    cf, kf = cert.get("certFile", ""), cert.get("keyFile", "")
    if cf and kf:
        return cf, kf
    domain = state.get("domain", "")
    if not domain:
        return "", ""
    return (
        os.path.join(LE_LIVE, domain, "fullchain.pem"),
        os.path.join(LE_LIVE, domain, "privkey.pem"),
    )


# --------------------------------------------------------------------------
# gost config rendering
# --------------------------------------------------------------------------
def _enabled_users(state):
    return [u for u in state.get("users", []) if u.get("enabled", True)]


def render_config(state):
    role = state.get("role", "entry")
    cf, kf = cert_paths(state)
    ports = state.get("ports", {})

    if role == "exit":
        return _render_exit(state, cf, kf, ports)
    return _render_entry(state, cf, kf, ports)


def _render_exit(state, cf, kf, ports):
    users = [{"username": u["username"], "password": u["password"]}
             for u in _enabled_users(state)]
    tunnel_port = int(ports.get("tunnel", 8443))
    cfg = {
        "services": [
            {
                "name": "relay-tunnel",
                "addr": f":{tunnel_port}",
                "handler": {"type": "relay", "auther": "tunnel-auth"},
                "listener": {
                    "type": "tls",
                    "tls": {"certFile": cf, "keyFile": kf},
                },
            }
        ],
        "authers": [
            {"name": "tunnel-auth", "auths": users}
        ],
    }
    return cfg


def _render_entry(state, cf, kf, ports):
    users = [{"username": u["username"], "password": u["password"]}
             for u in _enabled_users(state)]
    ex = state.get("exit", {})
    https_p = int(ports.get("https", 443))
    socks_p = int(ports.get("socks", 1080))
    http_p = int(ports.get("http", 8080))

    services = []
    if https_p:
        services.append({
            "name": "https-proxy",
            "addr": f":{https_p}",
            "handler": {"type": "http", "chain": "to-exit", "auther": "proxy-auth"},
            "listener": {"type": "tls", "tls": {"certFile": cf, "keyFile": kf}},
        })
    if socks_p:
        services.append({
            "name": "socks5-proxy",
            "addr": f":{socks_p}",
            "handler": {"type": "socks5", "chain": "to-exit", "auther": "proxy-auth"},
            "listener": {"type": "tcp"},
        })
    if http_p:
        services.append({
            "name": "http-proxy",
            "addr": f":{http_p}",
            "handler": {"type": "http", "chain": "to-exit", "auther": "proxy-auth"},
            "listener": {"type": "tcp"},
        })

    chain = {
        "name": "to-exit",
        "hops": [
            {
                "name": "hop-0",
                "nodes": [
                    {
                        "name": "exit",
                        "addr": f"{ex.get('host','')}:{int(ex.get('port', 8443))}",
                        "connector": {
                            "type": "relay",
                            "auth": {
                                "username": ex.get("user", ""),
                                "password": ex.get("password", ""),
                            },
                        },
                        "dialer": {
                            "type": "tls",
                            "tls": {
                                "serverName": ex.get("host", ""),
                                "secure": bool(ex.get("secure", True)),
                            },
                        },
                    }
                ],
            }
        ],
    }

    cfg = {
        "services": services,
        "chains": [chain],
        "authers": [{"name": "proxy-auth", "auths": users}],
    }
    return cfg


def write_config(state):
    cfg = render_config(state)
    os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(cfg, fh, indent=2)
    os.replace(tmp, CONFIG_PATH)
    try:
        os.chmod(CONFIG_PATH, 0o600)
    except PermissionError:
        pass
    return CONFIG_PATH


def reload_service():
    try:
        subprocess.run(["systemctl", "restart", GOST_SERVICE], check=True)
        return True, f"{GOST_SERVICE} restarted"
    except FileNotFoundError:
        return False, "systemctl not available"
    except subprocess.CalledProcessError as exc:
        return False, f"restart failed: {exc}"


def service_active():
    try:
        out = subprocess.run(["systemctl", "is-active", GOST_SERVICE],
                             capture_output=True, text=True)
        return out.stdout.strip()
    except FileNotFoundError:
        return "unknown"


def cert_expiry(state):
    cf, _ = cert_paths(state)
    if not cf or not os.path.exists(cf):
        return None
    try:
        out = subprocess.run(
            ["openssl", "x509", "-enddate", "-noout", "-in", cf],
            capture_output=True, text=True, check=True)
        return out.stdout.strip().replace("notAfter=", "")
    except Exception:
        return None


# --------------------------------------------------------------------------
# endpoints summary (what to put in WHMCS)
# --------------------------------------------------------------------------
def endpoints(state):
    role = state.get("role", "entry")
    domain = state.get("domain", "")
    ports = state.get("ports", {})
    out = []
    if role == "exit":
        out.append(("TLS relay tunnel", f"{domain}:{ports.get('tunnel',8443)}"))
        return out
    if ports.get("https"):
        out.append(("HTTPS proxy (valid SSL, use in WHMCS)",
                    f"https://{domain}:{ports.get('https')}"))
    if ports.get("socks"):
        out.append(("SOCKS5 proxy", f"socks5h://{domain}:{ports.get('socks')}"))
    if ports.get("http"):
        out.append(("HTTP proxy (plain)", f"http://{domain}:{ports.get('http')}"))
    return out


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
def cmd_init(args):
    if os.path.exists(STATE_PATH) and not args.force:
        raise SystemExit(f"{STATE_PATH} already exists (use --force to overwrite)")
    state = default_state(role=args.role, domain=args.domain)
    if args.cert_file:
        state["cert"]["certFile"] = args.cert_file
    if args.key_file:
        state["cert"]["keyFile"] = args.key_file
    for k in ("https", "socks", "http", "tunnel", "dashboard"):
        v = getattr(args, k, None)
        if v is not None:
            state["ports"][k] = v
    if args.role == "entry":
        state["exit"] = {
            "host": args.exit_host or "",
            "port": args.exit_port,
            "user": args.tunnel_user or "",
            "password": args.tunnel_pass or "",
            "secure": not args.tunnel_insecure,
        }
    # admin login
    admin_pw = args.admin_pass or gen_secret(16)
    salt, h = hash_password(admin_pw)
    state["admin"] = {"username": args.admin_user, "salt": salt, "hash": h}
    save_state(state)
    print(f"initialized state at {STATE_PATH}")
    print(f"dashboard admin user: {args.admin_user}")
    print(f"dashboard admin pass: {admin_pw}")


def cmd_useradd(args):
    state = load_state()
    for u in state["users"]:
        if u["username"] == args.username:
            raise SystemExit(f"user exists: {args.username}")
    pw = args.password or gen_secret(18)
    state["users"].append({"username": args.username, "password": pw, "enabled": True})
    save_state(state)
    print(f"added user {args.username}")
    print(f"password: {pw}")
    if args.apply:
        cmd_apply(args)


def cmd_userdel(args):
    state = load_state()
    before = len(state["users"])
    state["users"] = [u for u in state["users"] if u["username"] != args.username]
    if len(state["users"]) == before:
        raise SystemExit(f"no such user: {args.username}")
    save_state(state)
    print(f"removed user {args.username}")
    if args.apply:
        cmd_apply(args)


def cmd_passwd(args):
    state = load_state()
    pw = args.password or gen_secret(18)
    found = False
    for u in state["users"]:
        if u["username"] == args.username:
            u["password"] = pw
            found = True
    if not found:
        raise SystemExit(f"no such user: {args.username}")
    save_state(state)
    print(f"password for {args.username}: {pw}")
    if args.apply:
        cmd_apply(args)


def cmd_listusers(args):
    state = load_state()
    for u in state["users"]:
        flag = "on " if u.get("enabled", True) else "off"
        print(f"[{flag}] {u['username']}  {u['password']}")


def cmd_setport(args):
    state = load_state()
    if args.name not in state["ports"]:
        raise SystemExit(f"unknown port name: {args.name}")
    state["ports"][args.name] = args.value
    save_state(state)
    print(f"{args.name} port -> {args.value}")
    if args.apply:
        cmd_apply(args)


def cmd_setexit(args):
    state = load_state()
    ex = state.setdefault("exit", {})
    if args.host is not None:
        ex["host"] = args.host
    if args.port is not None:
        ex["port"] = args.port
    if args.user is not None:
        ex["user"] = args.user
    if args.password is not None:
        ex["password"] = args.password
    if args.insecure:
        ex["secure"] = False
    save_state(state)
    print("exit/tunnel settings updated")
    if args.apply:
        cmd_apply(args)


def cmd_render(args):
    state = load_state()
    path = write_config(state)
    print(f"wrote {path}")


def cmd_apply(args):
    state = load_state()
    write_config(state)
    ok, msg = reload_service()
    print(msg)
    if not ok:
        sys.exit(1)


def cmd_status(args):
    state = load_state()
    print(f"role:     {state.get('role')}")
    print(f"domain:   {state.get('domain')}")
    print(f"gost:     {service_active()}")
    exp = cert_expiry(state)
    print(f"cert exp: {exp or 'unknown / not issued yet'}")
    print("endpoints:")
    for label, val in endpoints(state):
        print(f"  - {label}: {val}")
    print(f"users:    {len(_enabled_users(state))} enabled / {len(state.get('users', []))} total")


def cmd_show(args):
    print(json.dumps(render_config(load_state()), indent=2))


def build_parser():
    p = argparse.ArgumentParser(description="Manage the WHMCS SSL proxy stack (gost).")
    sub = p.add_subparsers(dest="cmd", required=True)

    pi = sub.add_parser("init", help="create the state file")
    pi.add_argument("--role", choices=["entry", "exit"], required=True)
    pi.add_argument("--domain", required=True)
    pi.add_argument("--cert-file", default="")
    pi.add_argument("--key-file", default="")
    pi.add_argument("--https", type=int)
    pi.add_argument("--socks", type=int)
    pi.add_argument("--http", type=int)
    pi.add_argument("--tunnel", type=int)
    pi.add_argument("--dashboard", type=int)
    pi.add_argument("--exit-host", default="")
    pi.add_argument("--exit-port", type=int, default=8443)
    pi.add_argument("--tunnel-user", default="")
    pi.add_argument("--tunnel-pass", default="")
    pi.add_argument("--tunnel-insecure", action="store_true")
    pi.add_argument("--admin-user", default="admin")
    pi.add_argument("--admin-pass", default="")
    pi.add_argument("--force", action="store_true")
    pi.set_defaults(func=cmd_init)

    pu = sub.add_parser("useradd", help="add a proxy user")
    pu.add_argument("username")
    pu.add_argument("--password", default="")
    pu.add_argument("--apply", action="store_true")
    pu.set_defaults(func=cmd_useradd)

    pd = sub.add_parser("userdel", help="remove a proxy user")
    pd.add_argument("username")
    pd.add_argument("--apply", action="store_true")
    pd.set_defaults(func=cmd_userdel)

    pp = sub.add_parser("passwd", help="reset a proxy user's password")
    pp.add_argument("username")
    pp.add_argument("--password", default="")
    pp.add_argument("--apply", action="store_true")
    pp.set_defaults(func=cmd_passwd)

    pl = sub.add_parser("list-users", help="list proxy users")
    pl.set_defaults(func=cmd_listusers)

    ps = sub.add_parser("set-port", help="change a listener port")
    ps.add_argument("name", choices=["https", "socks", "http", "tunnel", "dashboard"])
    ps.add_argument("value", type=int)
    ps.add_argument("--apply", action="store_true")
    ps.set_defaults(func=cmd_setport)

    pe = sub.add_parser("set-exit", help="configure the tunnel to the exit node")
    pe.add_argument("--host")
    pe.add_argument("--port", type=int)
    pe.add_argument("--user")
    pe.add_argument("--password")
    pe.add_argument("--insecure", action="store_true")
    pe.add_argument("--apply", action="store_true")
    pe.set_defaults(func=cmd_setexit)

    sub.add_parser("render", help="write gost config from state").set_defaults(func=cmd_render)
    sub.add_parser("apply", help="write config and restart gost").set_defaults(func=cmd_apply)
    sub.add_parser("status", help="show status summary").set_defaults(func=cmd_status)
    sub.add_parser("show-config", help="print rendered gost config").set_defaults(func=cmd_show)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
