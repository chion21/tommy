"""Run the Tommy server on your own laptop, reachable from your phone anywhere.

First run: asks for your Gemini API key, creates .env with random secrets (SQLite database, no Docker).
Every run: starts the server on port 8000 and a free Cloudflare tunnel, then prints the public https address.
Use start_server.bat on Windows — it calls this file.
"""
import getpass
import os
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ENV = os.path.join(HERE, ".env")
IS_WIN = os.name == "nt"
CF_NAME = "cloudflared.exe" if IS_WIN else "cloudflared"
CF_PATH = os.path.join(HERE, CF_NAME)
CF_URL = ("https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
          if IS_WIN else
          "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64")


def make_env() -> None:
    if os.path.exists(ENV):
        return
    print("\n=== Tommy first-time setup ===")
    key = getpass.getpass("Paste your Gemini API key (hidden, then Enter): ").strip()
    admin = secrets.token_urlsafe(32)
    with open(ENV, "w", encoding="utf-8") as f:
        f.write(f"DATABASE_URL=sqlite:///{os.path.join(HERE, 'tommy.db').replace(os.sep, '/')}\n")
        f.write(f"JWT_SECRET={secrets.token_urlsafe(48)}\n")
        f.write(f"MASTER_KEY={secrets.token_urlsafe(48)}\n")
        f.write(f"ADMIN_API_KEY={admin}\n")
        f.write(f"GEMINI_API_KEY={key}\n")
    print("\n================ SAVE THIS ================")
    print(f"Admin key: {admin}")
    print("Also keep a copy of server\\.env — never share it.")
    print("===========================================\n")


def find_cloudflared() -> str | None:
    if os.path.exists(CF_PATH):
        return CF_PATH
    found = shutil.which("cloudflared")
    if found:
        return found
    print("Downloading Cloudflare tunnel (one time, ~20 MB)...")
    try:
        urllib.request.urlretrieve(CF_URL, CF_PATH)
        if not IS_WIN:
            os.chmod(CF_PATH, 0o755)
        return CF_PATH
    except Exception as e:  # noqa: BLE001
        print(f"Could not download cloudflared ({e}). The server will work on this Wi-Fi only.")
        return None


def watch_tunnel(proc: subprocess.Popen) -> None:
    # real tunnel names look like "word-word-word-word.trycloudflare.com" (skip api.trycloudflare.com in logs)
    pattern = re.compile(r"https://(?!api\.)[a-z0-9]+(?:-[a-z0-9]+)+\.trycloudflare\.com")
    for line in proc.stdout:  # type: ignore[union-attr]
        m = pattern.search(line)
        if m:
            url = m.group(0)
            with open(os.path.join(HERE, "server_url.txt"), "w") as f:
                f.write(url)
            print("\n" + "=" * 60)
            print(f"  ✅ Tommy server is online:  {url}")
            print("  Put this address in the app's 'Server' box on the login screen.")
            print("  (It changes each time you restart this window.)")
            print("=" * 60 + "\n")


def main() -> None:
    make_env()
    server = subprocess.Popen([sys.executable, "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0",
                               "--port", "8000"], cwd=HERE)
    time.sleep(3)
    tunnel = None
    cf = find_cloudflared()
    if cf:
        tunnel = subprocess.Popen([cf, "tunnel", "--no-autoupdate", "--url", "http://localhost:8000"],
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, cwd=HERE)
        threading.Thread(target=watch_tunnel, args=(tunnel,), daemon=True).start()
    print("Server running. Keep this window open. Press Ctrl+C to stop.")
    try:
        server.wait()
    except KeyboardInterrupt:
        pass
    finally:
        for p in (tunnel, server):
            if p and p.poll() is None:
                p.terminate()


if __name__ == "__main__":
    main()
