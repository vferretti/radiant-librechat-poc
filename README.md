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
| `prompts/questions-{fr,en}.json` | Les banques de questions cliniques sauvegardées (variants rares, de novo, hétérozygotes composés, Exomiser, phénotypes) |
| `radiant-tools/server.py` | **Bibliothèque d'outils de visualisation** (serveur MCP « viz ») : `venn_trio` / `venn_duo` — diagrammes de Venn des SNV familiaux, rendus en image dans la conversation |

## Installation — bootstrap scripté d'une instance

Prérequis : Docker + docker compose, `jq`, accès réseau à la zone qlin (VPN), un client Keycloak dans le realm `qlin` avec les redirect URIs LibreChat autorisées, une clé API Anthropic (POC) ou Bedrock (zone).

```bash
# 1. LibreChat : cloner l'upstream, y déposer la config de ce dépôt
git clone https://github.com/danny-avila/LibreChat && cd LibreChat
cp <ce-dépôt>/librechat/librechat.yaml .
cp <ce-dépôt>/librechat/docker-compose.override.yml .
cp -r <ce-dépôt>/radiant-tools ./radiant-tools   # code du serveur MCP « viz » (contexte de build)
cp <ce-dépôt>/librechat/.env.example .env   # puis remplir les secrets
docker compose up -d api mongodb meilisearch
docker compose up -d biomcp radiant-tools   # après api (namespace réseau partagé)

# 2. Premier login (crée l'utilisateur en base) : ouvrir http://localhost:3080
#    → bouton OpenID (SSO Keycloak)

# 3. Seeder l'agent et les banques de questions (depuis ce dépôt)
./scripts/seed-agent.sh agent/assistant-radiant.json     # affiche l'agent_id
./scripts/seed-prompts.sh prompts/questions-fr.json
./scripts/seed-prompts.sh prompts/questions-en.json

# 4. Portail : branche feat/SJRA-1835-assistant-ia du dépôt radiant-portal ;
#    reporter l'agent_id de l'étape 3 (LIBRECHAT_AGENT_ID) et l'URL LibreChat.
```

Réglage utilisateur recommandé : Paramètres → Chat → Prompts → désactiver « Envoyer les prompts à la sélection » (permet d'éditer une question avant envoi).

**Démos bilingues** : supprimer les questions d'une langue dans le panneau Prompts, puis les recréer avec `seed-prompts.sh prompts/questions-<fr|en>.json`.

⚠️ L'agent et les questions vivent dans MongoDB (pas dans les fichiers) : sur toute nouvelle instance, l'`agent_id` change — les scripts de seed sont la source de vérité, pas la base d'une instance précédente.

## Recherche de littérature (BioMCP)

Le `docker-compose.override.yml` inclut un service **biomcp** ([genomoncology/biomcp](https://github.com/genomoncology/biomcp)) : littérature PubMed/PubTator3 (noms de variants normalisés), annotations MyVariant.info, ClinicalTrials.gov. Il partage l'espace réseau du conteneur `api` (la protection anti-DNS-rebinding de FastMCP n'accepte que `Host: localhost`) — d'où l'URL `http://localhost:8000/mcp` dans le yaml. 5 outils attachés à l'agent (article_searcher/getter, variant_searcher/getter, gene_getter), avec interdiction explicite d'envoyer toute donnée patient à ces APIs publiques. **Après tout redémarrage du conteneur `api`, redémarrer `biomcp`** (`docker compose restart biomcp`).

## Redémarrer l'environnement au quotidien

Une fois l'installation faite, relancer la POC après un redémarrage du poste (ou une session fermée) :

```bash
# 1. LibreChat + MCP (les conteneurs survivent aux redémarrages de session,
#    mais pas à un reboot ; -d = arrière-plan)
cd ~/src/LibreChat
docker compose up -d api mongodb meilisearch biomcp radiant-tools

# 2. Portail Radiant (s'arrête avec la session — à relancer à chaque fois)
cd ~/src/radiant-portal/frontend/portals/radiant
npm run dev:radiant          # → http://localhost:3000  (LibreChat : http://localhost:3080)
```

Après avoir redémarré **uniquement** le conteneur `api` (ex. changement de `librechat.yaml` ou de `.env`) :

```bash
cd ~/src/LibreChat && docker compose restart api && sleep 5 && docker compose restart biomcp radiant-tools
```

Vérifications utiles :

```bash
docker ps --format "{{.Names}}\t{{.Status}}"                      # conteneurs actifs
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3080/login   # LibreChat (attendu 200)
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/        # portail (attendu 302 → Keycloak)
# Keycloak de la zone joignable ? (attendu 200 ; 404 = panne côté zone, rien à corriger ici)
curl -s -o /dev/null -w "%{http_code}\n" https://auth.dev.qlin.aws.sante.quebec/realms/qlin/.well-known/openid-configuration
docker logs LibreChat --since 2m 2>&1 | grep -E "\[MCP\] Initialized"  # attendu : 3 serveurs
```

## Bibliothèque d'outils de visualisation (serveur MCP « viz »)

Patron pour rendre réutilisable tout traitement que l'agent referait laborieusement à chaque case : **StarRocks agrège (une requête SQL, recette dans les instructions de l'agent) → un outil maison rend le résultat** (image affichée dans la conversation). Premier duo d'outils : `venn_trio`/`venn_duo` (chevauchement des SNV d'une famille, cercles non à l'échelle, palette pastel, étiquettes dans la langue de la question). Seuls des **comptes agrégés** transitent par le modèle — jamais de listes de variants ni de données patient.

Pour **ajouter un outil** : une fonction `@mcp.tool()` de plus dans `radiant-tools/server.py` (candidats : pedigree, couverture, tableau ACMG…), `docker compose build radiant-tools && docker compose up -d radiant-tools`, attacher l'outil à l'agent et documenter la recette dans ses instructions. Comme biomcp, le conteneur partage le namespace réseau d'`api` (port **8001**) — le redémarrer après tout redémarrage d'`api`. À maturité, ces outils ont vocation à migrer dans le MCP Radiant officiel.

## Réglages utilisateur recommandés

Dans Paramètres → Chat : désactiver « Envoyer les prompts à la sélection » (édition des questions avant envoi), désactiver « Ouvrir les menus déroulants de réflexion par défaut » et « autoExpandTools » (blocs Pensées/outils repliés, consultables au clic). Réglages par navigateur — à documenter dans le guide d'accueil des utilisateurs.

## Pièges connus (résolus — détail dans la page Notion)

- **Instructions d'agent en anglais obligatoire pour le bilinguisme** : des instructions rédigées en français font répondre l'agent en français même à un message anglais (la masse du prompt système dicte la langue). Instructions en anglais + règle de langue absolue en tête = bascule fiable FR/EN selon le message de l'utilisateur.

- **Allowlist anti-SSRF** : déclarer le domaine du MCP **et** celui du Keycloak dans `mcpSettings.allowedDomains`, sinon `Domain not allowed` / `resolves to a private IP address`.
- **DCR refusé** : le Keycloak de la zone rejette l'enregistrement dynamique de client (« Trusted Hosts ») → client OAuth pré-configuré obligatoire (bloc `oauth:` du yaml).
- **Reconnexion MCP quotidienne** : sans `offline_access` dans le scope, le refresh token meurt avec la session SSO (`invalid_grant: Token is not active`).
- **Iframe** : Keycloak refuse de s'afficher dans la modale (`X-Frame-Options`) → premier login dans un onglet normal.
- **`.env` relu au démarrage seulement** : redémarrer le conteneur après toute modification.
- **`titlePrompt` doit contenir `{convo}`** : LibreChat y injecte la conversation ; sans lui, le générateur titre à l'aveugle (« Empty conversation with no content »).
- **`endpoints.all` remplace, ne fusionne pas** : c'est la config lue en priorité pour le titrage — y mettre tous les champs voulus.
- **Chaque redémarrage du conteneur `api` coupe les connexions MCP en mémoire** : la première conversation suivante redemande brièvement « Authenticate » (disparaît avec l'OBO en production).

## Sécurité

- Aucun secret dans ce dépôt : le `client_secret` Keycloak est référencé par variable d'environnement dans le yaml (`${OPENID_CLIENT_SECRET}`), la clé API vit dans le `.env` local.
- L'agent n'a **que des outils de lecture** (`write_query` retiré).
- Chaque utilisateur porte ses propres droits jusqu'à la base : le LLM ne voit que ce que la personne connectée peut voir.

## Cible production (zone d'accueil)

Bedrock + rôle IAM (aucune clé), client Keycloak dédié `librechat`, échange de token OBO (zéro clic pour le MCP), `OPENID_AUTO_REDIRECT`, `modelSpec` unique. Checklist complète dans la page Notion.
