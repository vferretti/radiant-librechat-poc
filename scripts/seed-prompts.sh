#!/usr/bin/env bash
# Recrée une banque de questions dans LibreChat à partir d'un fichier JSON.
# Usage : ./scripts/seed-prompts.sh prompts/questions-fr.json [<userId>]
# Prérequis : conteneur LibreChat démarré ; jq ; l'utilisateur cible existe.
# Flux démo bilingue : supprimer les questions d'une langue dans l'UI (panneau
# Prompts), puis recréer l'autre banque avec ce script.
set -euo pipefail

FILE="${1:?usage: seed-prompts.sh <fichier.json> [userId]}"
USER_ID="${2:-$(docker exec chat-mongodb mongosh LibreChat --quiet --eval 'print(db.users.findOne({}, {_id:1})._id.str)')}"
BASE_URL="${LIBRECHAT_URL:-http://localhost:3080}"

# Jeton signé localement avec le JWT_SECRET du conteneur (jamais exposé)
TOKEN=$(docker exec LibreChat node -e "require('dotenv').config({path:'/app/.env'}); \
  console.log(require('jsonwebtoken').sign({id:'$USER_ID'}, process.env.JWT_SECRET, {expiresIn:'10m'}))")

COUNT=0
while IFS= read -r payload; do
  RES=$(curl -s -X POST "$BASE_URL/api/prompts" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "$payload")
  if echo "$RES" | jq -e '.prompt._id' > /dev/null 2>&1; then
    COUNT=$((COUNT + 1))
    echo "✓ $(echo "$payload" | jq -r '.group.name')"
  else
    echo "✗ échec: $(echo "$payload" | jq -r '.group.name') — $RES" >&2
  fi
done < <(jq -c '.[]' "$FILE")

echo "$COUNT question(s) créée(s) pour l'utilisateur $USER_ID"
