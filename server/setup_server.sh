#!/usr/bin/env bash
# One-time setup on the VPS. Run from the server/ folder:  bash setup_server.sh
# Creates .env with strong random secrets, sets the domain, and starts everything.
set -euo pipefail
cd "$(dirname "$0")"

if [ -f .env ]; then
  echo ".env already exists — not overwriting (MASTER_KEY must never change after launch)."
else
  read -rp "Domain (e.g. tommyai.duckdns.org): " DOMAIN
  read -rsp "Gemini API key (hidden): " GEMINI; echo
  rnd() { python3 -c "import secrets;print(secrets.token_urlsafe($1))"; }
  PGPASS=$(rnd 24); ADMIN=$(rnd 32)
  cat > .env <<EOF
DATABASE_URL=postgresql+psycopg://tommy:${PGPASS}@db:5432/tommy
POSTGRES_PASSWORD=${PGPASS}
JWT_SECRET=$(rnd 48)
MASTER_KEY=$(rnd 48)
ADMIN_API_KEY=${ADMIN}
GEMINI_API_KEY=${GEMINI}
LIVE_MODEL=gemini-3.8-live
TEXT_MODEL=gemini-3.8-flash
EOF
  chmod 600 .env
  printf '%s {\n    reverse_proxy api:8000\n}\n' "$DOMAIN" > Caddyfile
  echo
  echo "================ SAVE THIS SOMEWHERE SAFE ================"
  echo "Admin key (for creating license keys): ${ADMIN}"
  echo "Also back up the file server/.env — losing MASTER_KEY makes saved memories unreadable."
  echo "=========================================================="
fi

docker compose up -d --build
echo "Waiting for the API..."
sleep 15
DOMAIN=$(head -1 Caddyfile | awk '{print $1}')
curl -fsS "https://${DOMAIN}/health" && echo && echo "✅ Server is live at https://${DOMAIN}" \
  || echo "⚠️  Not reachable yet. Check: ports 80/443 open, DuckDNS IP correct, then: docker compose logs -f"
