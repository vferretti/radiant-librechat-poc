#!/usr/bin/env bash
# Crée l'agent « IA Radiant » dans LibreChat à partir de agent/assistant-radiant.json.
# Usage : ./scripts/seed-agent.sh [agent/assistant-radiant.json] [<userId>]
# Affiche le nouvel agent_id — À REPORTER dans la configuration du portail
# (LIBRECHAT_AGENT_ID dans apps/case/src/entity/layout/header.tsx, ou la
# variable d'environnement qui le remplacera).
# Prérequis : conteneur LibreChat démarré ; jq ; l'utilisateur cible existe
# (premier login fait). Les outils MCP référencés supposent le serveur
# `radiant` déclaré dans librechat.yaml.
set -euo pipefail

FILE="${1:-agent/assistant-radiant.json}"
USER_ID="${2:-$(docker exec chat-mongodb mongosh LibreChat --quiet --eval 'print(db.users.findOne({}, {_id:1})._id.str)')}"
BASE_URL="${LIBRECHAT_URL:-http://localhost:3080}"

TOKEN=$(docker exec LibreChat node -e "require('dotenv').config({path:'/app/.env'}); \
  console.log(require('jsonwebtoken').sign({id:'$USER_ID'}, process.env.JWT_SECRET, {expiresIn:'10m'}))")

RES=$(curl -s -X POST "$BASE_URL/api/agents" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d @"$FILE")

AGENT_ID=$(echo "$RES" | jq -r '.id // empty')
if [ -z "$AGENT_ID" ]; then
  echo "✗ échec de création : $RES" >&2
  exit 1
fi

echo "✓ agent créé : $AGENT_ID (propriétaire $USER_ID)"
echo "→ Reporter cet identifiant dans la configuration du portail (LIBRECHAT_AGENT_ID)."
