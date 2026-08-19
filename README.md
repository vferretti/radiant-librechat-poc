# POC — Assistant IA conversationnel pour le portail Radiant

Bouton « Analyser avec l'IA » dans la page **Case** du portail Radiant, ouvrant **LibreChat** en modale, branché au **serveur MCP Radiant** avec les droits de l'utilisateur connecté (OAuth Keycloak par personne → autorisations **Apache Ranger** appliquées au niveau des données : tenants, masquage PII, row-filters).

> 📄 Documentation complète (architecture, frictions rencontrées → solutions, exigences pour le déploiement en zone d'accueil) : page Notion **« Radiant LibreChat »** (espace Ferlab → Analyses).

## Architecture

```
Portail Radiant ──bouton page Case──▶ LibreChat (modale iframe)
      │ SSO Keycloak (realm qlin)          │ OAuth MCP par utilisateur
      ▼                                    ▼
   Keycloak ◀──────────────── MCP Radiant (mcp.dev.qlin.aws.sante.quebec)
                                           │ JWT utilisateur
                                           ▼
                              StarRocks + Ranger (droits individuels)
                                           ▼
                     Claude (API Anthropic en POC → Bedrock en zone)
```

## Contenu du dépôt

| Chemin | Rôle |
|---|---|
| `librechat/librechat.yaml` | Config LibreChat : allowlist des domaines MCP/OAuth, serveur MCP `radiant` avec client OAuth pré-configuré (`offline_access` pour survivre à l'expiration de session SSO) |
| `librechat/docker-compose.override.yml` | Montage du `librechat.yaml` dans le conteneur |
| `librechat/.env.example` | Variables d'environnement (placeholders — **jamais de secrets dans ce dépôt**) |
| `agent/assistant-radiant.json` | L'agent LibreChat : modèle, **instructions complètes** (modèle de données Radiant + méthode d'analyse en 3-4 requêtes + style de réponse concis) et liste d'outils élaguée (lecture seule) |
| `prompts/questions-cliniques.json` | Les 5 questions cliniques sauvegardées (variants rares, de novo, hétérozygotes composés, Exomiser, phénotypes) |

## Installation (dev local)

Prérequis : Docker + docker compose, accès réseau à la zone qlin (VPN), un client Keycloak dans le realm `qlin` avec les redirect URIs `http://localhost:3080/*` autorisées, une clé API Anthropic (POC).

1. **LibreChat** : cloner [LibreChat](https://github.com/danny-avila/LibreChat), y copier `librechat/librechat.yaml`, `librechat/docker-compose.override.yml` et un `.env` rempli depuis `librechat/.env.example`, puis `docker compose up -d api mongodb meilisearch`.
2. **Agent** : dans LibreChat → Agents → créer un agent et coller le contenu d'`agent/assistant-radiant.json` (nom, modèle, instructions) ; attacher les outils MCP `radiant` listés dans `tools` (après avoir connecté le serveur MCP une première fois). Noter l'`agent_id`.
3. **Questions sauvegardées** : panneau Prompts → créer les 5 entrées de `prompts/questions-cliniques.json` → activer le partage global.
4. **Portail** : branche `feat/SJRA-XXXX-assistant-ia` du dépôt radiant-portal (bouton + modale dans `apps/case/src/entity/layout/header.tsx`). Y mettre l'`agent_id` de l'étape 2 et l'URL LibreChat.
5. **Réglage utilisateur recommandé** : Paramètres → Chat → Prompts → désactiver « Envoyer les prompts à la sélection » (permet d'éditer une question avant envoi).

## Pièges connus (résolus — détail dans la page Notion)

- **Allowlist anti-SSRF** : déclarer le domaine du MCP **et** celui du Keycloak dans `mcpSettings.allowedDomains`, sinon `Domain not allowed` / `resolves to a private IP address`.
- **DCR refusé** : le Keycloak de la zone rejette l'enregistrement dynamique de client (« Trusted Hosts ») → client OAuth pré-configuré obligatoire (bloc `oauth:` du yaml).
- **Reconnexion MCP quotidienne** : sans `offline_access` dans le scope, le refresh token meurt avec la session SSO (`invalid_grant: Token is not active`).
- **Iframe** : Keycloak refuse de s'afficher dans la modale (`X-Frame-Options`) → premier login dans un onglet normal.
- **`.env` relu au démarrage seulement** : redémarrer le conteneur après toute modification.

## Sécurité

- Aucun secret dans ce dépôt : le `client_secret` Keycloak est référencé par variable d'environnement dans le yaml (`${OPENID_CLIENT_SECRET}`), la clé API vit dans le `.env` local.
- L'agent n'a **que des outils de lecture** (`write_query` retiré).
- Chaque utilisateur porte ses propres droits jusqu'à la base : le LLM ne voit que ce que la personne connectée peut voir.

## Cible production (zone d'accueil)

Bedrock + rôle IAM (aucune clé), client Keycloak dédié `librechat`, échange de token OBO (zéro clic pour le MCP), `OPENID_AUTO_REDIRECT`, `modelSpec` unique. Checklist complète dans la page Notion.
