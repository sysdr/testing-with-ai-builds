#!/usr/bin/env bash
# cleanup.sh — stop services, prune unused Docker resources, strip git-unfriendly files
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

info() { echo -e "${YELLOW}${BOLD}▶${RESET} $*"; }
ok()   { echo -e "${GREEN}  ✓${RESET} $*"; }
warn() { echo -e "${RED}  !${RESET} $*"; }

echo ""
echo -e "${BOLD}════════════════════════════════════════════════${RESET}"
echo -e "${BOLD} Lesson 2 · cleanup${RESET}"
echo -e "${BOLD}════════════════════════════════════════════════${RESET}"
echo ""

# ─── 1. stop Compose stack ─────────────────────────────────────────────────────
info "[1/5] Stopping Compose services"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if [ -f "${APP_DIR}/docker-compose.yml" ]; then
    docker compose -f "${APP_DIR}/docker-compose.yml" --project-directory "${APP_DIR}" down --volumes --remove-orphans 2>/dev/null || true
    ok "qatp-lesson-02 stack stopped (containers, orphans, volumes)"
  else
    warn "no docker-compose.yml — skipping compose down"
  fi
else
  warn "Docker engine not reachable — skipping compose down"
fi

# ─── 2. stop leftover containers, prune unused Docker resources ───────────────
info "[2/5] Stopping leftover containers and pruning unused Docker resources"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  running="$(docker ps -q 2>/dev/null || true)"
  if [ -n "$running" ]; then
    # shellcheck disable=SC2086
    docker stop $running >/dev/null
    ok "remaining containers stopped"
  else
    ok "no other running containers"
  fi

  docker container prune -f >/dev/null
  docker image prune -af >/dev/null
  docker network prune -f >/dev/null
  docker volume prune -f >/dev/null
  docker builder prune -af >/dev/null 2>/dev/null || true
  ok "unused containers, images, networks, volumes, and build cache removed"
else
  warn "Docker engine not reachable — skipping prune"
fi

# ─── 3. remove paths that should not be git-pushed ────────────────────────────
info "[3/5] Removing local-only files (reports, caches, .env)"
removed=0
remove_path() {
  local p="$1"
  if [ -e "$p" ]; then
    rm -rf "$p"
    ok "removed ${p#${APP_DIR}/}"
    removed=$((removed + 1))
  fi
}

remove_path "${APP_DIR}/venv"
remove_path "${APP_DIR}/.venv"
remove_path "${APP_DIR}/.pytest_cache"
remove_path "${APP_DIR}/__pycache__"
remove_path "${APP_DIR}/.env"
remove_path "${APP_DIR}/.coverage"

if [ -d "${APP_DIR}/reports" ]; then
  find "${APP_DIR}/reports" -type f ! -name '.gitkeep' -delete 2>/dev/null || true
  ok "cleared reports/ (generated health, openapi, JWT register dumps)"
  removed=$((removed + 1))
fi

find "${APP_DIR}" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
find "${APP_DIR}" -type d -name '.pytest_cache' -prune -exec rm -rf {} + 2>/dev/null || true
find "${APP_DIR}" -type f -name '*.pyc' -delete 2>/dev/null || true
find "${APP_DIR}" -type f -name '.coverage' -delete 2>/dev/null || true
find "${APP_DIR}" -type d -name '.mypy_cache' -prune -exec rm -rf {} + 2>/dev/null || true
find "${APP_DIR}" -type d -name '.ruff_cache' -prune -exec rm -rf {} + 2>/dev/null || true

if [ "$removed" -eq 0 ]; then
  ok "no extra local-only paths present"
fi

# ─── 4. strip secrets ──────────────────────────────────────────────────────────
info "[4/5] Checking for API keys and committed tokens"
scan_file="$(mktemp)"
if grep -RInE --exclude-dir='.git' --exclude='cleanup.sh' --exclude='setup.sh' \
    '(api[_-]?key|secret_key|openai|sk-[A-Za-z0-9]|ghp_|github_pat_|eyJ[A-Za-z0-9_-]+\.eyJ)' \
    "${APP_DIR}" >"$scan_file" 2>/dev/null; then
  warn "possible secret-like strings found:"
  cat "$scan_file"
else
  ok "no API keys or dumped JWTs found in remaining files"
fi
rm -f "$scan_file"

# ─── 5. stop Docker engine ─────────────────────────────────────────────────────
info "[5/5] Stopping Docker engine"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if command -v systemctl >/dev/null 2>&1; then
    sudo -n systemctl stop docker.socket docker.service 2>/dev/null || true
  fi
  sudo -n service docker stop 2>/dev/null || true
  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "Stop-Process -Name 'Docker Desktop','com.docker.backend','com.docker.build','docker-agent' -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
  fi
  if docker info >/dev/null 2>&1; then
    warn "Docker engine still running. Stop Docker Desktop from Windows if you need the engine fully off."
  else
    ok "Docker engine stopped"
  fi
elif command -v docker >/dev/null 2>&1; then
  ok "Docker engine already stopped"
else
  ok "docker CLI not installed"
fi

echo ""
echo -e "${BOLD}Done.${RESET} Source stays; reports, caches, tokens, and unused Docker resources are gone."
echo ""
