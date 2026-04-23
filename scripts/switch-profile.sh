#!/usr/bin/env bash
#
# Privasimu AI — Profile Switcher
#
# Swap antara dual AI profiles:
#   qwen3-32b    — Stable production profile (32B dense + VL fallback)
#   qwen3.6-27b  — Pilot profile (27B with built-in VLM)
#
# Usage:
#   bash scripts/switch-profile.sh                   # interactive
#   bash scripts/switch-profile.sh qwen3-32b         # direct
#   bash scripts/switch-profile.sh qwen3.6-27b       # direct
#

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

PROFILES_DIR=".env.profiles"

# List available profiles
list_profiles() {
    echo "Available profiles:"
    for f in "$PROFILES_DIR"/*.env; do
        local name
        name=$(basename "$f" .env)
        local desc
        desc=$(grep "^PROFILE_DESC=" "$f" | cut -d= -f2- | tr -d '"')
        local tier
        tier=$(grep "^PROFILE_TIER=" "$f" | cut -d= -f2- | tr -d '"')
        printf "  %-15s [%s]  %s\n" "$name" "$tier" "$desc"
    done
}

# Show current profile
current_profile() {
    if [[ -f .env ]]; then
        grep "^PROFILE_NAME=" .env 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "unknown"
    else
        echo "none (.env belum ada)"
    fi
}

# Argument handling
PROFILE="${1:-}"

if [[ -z "$PROFILE" ]]; then
    echo "===================================================="
    echo " Privasimu AI — Profile Switcher"
    echo "===================================================="
    echo ""
    echo "Current: $(current_profile)"
    echo ""
    list_profiles
    echo ""
    read -p "Pilih profile (atau Enter untuk cancel): " PROFILE
    [[ -z "$PROFILE" ]] && { echo "Cancelled."; exit 0; }
fi

PROFILE_FILE="$PROFILES_DIR/${PROFILE}.env"

if [[ ! -f "$PROFILE_FILE" ]]; then
    echo "❌ Profile '$PROFILE' tidak ditemukan."
    echo ""
    list_profiles
    exit 1
fi

# Backup existing .env kalau ada
if [[ -f .env ]]; then
    BACKUP=".env.backup.$(date +%Y%m%d-%H%M%S)"
    cp .env "$BACKUP"
    echo "📦 Backup .env lama: $BACKUP"
fi

# Copy profile
cp "$PROFILE_FILE" .env
echo "✅ Switched to profile: $PROFILE"
echo ""
grep "^PROFILE_" .env | sed 's/^/   /'
echo ""

# Prompt restart
if docker compose ps --quiet 2>/dev/null | grep -q .; then
    echo "⚠️  Stack sedang running. Restart diperlukan untuk apply profile baru."
    echo ""
    read -p "Restart sekarang? [Y/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        echo "🛑 Stopping current stack..."
        docker compose down
        echo ""
        echo "🚀 Starting dengan profile $PROFILE..."
        bash scripts/start.sh
    else
        echo ""
        echo "Manual restart kapan saja:"
        echo "   docker compose down"
        echo "   bash scripts/start.sh"
    fi
else
    echo "ℹ️  Stack belum running. Start dengan:"
    echo "   bash scripts/start.sh"
fi
