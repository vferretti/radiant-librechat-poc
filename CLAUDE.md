# CLAUDE.md — POC assistant IA Radiant × LibreChat

Contexte pour Claude Code (et tout repreneur) : ce dépôt est la source de vérité
d'une POC fonctionnelle de bout en bout. Lire ce fichier puis le README avant d'agir.

## Vue d'ensemble (état : fonctionnel, 2026-08-20)

Bouton « Analyser avec l'IA » dans la page Case du portail Radiant → LibreChat en
modale (choix : nouvelle analyse / reprendre l'historique) → agent « IA Radiant »
branché à 3 serveurs MCP : `radiant` (StarRocks via OAuth Keycloak **par
utilisateur** → droits Apache Ranger individuels), `biomcp` (littérature
PubMed/PubTator, MyVariant), `viz` (bibliothèque maison : Venn trio/duo).
Bilingue FR/EN de bout en bout. Titres de conversation « Case <n> Analysis ».
Liens variants → fiche occurrence du portail (deep-link corrigé côté portail).

Trois emplacements de travail :

| Où | Quoi | Git |
|---|---|---|
| `~/src/radiant-portal` | frontend (bouton, modale, deep-link) | branche `feat/SJRA-1835-assistant-ia` (ticket SJRA-1835, Jira d3b.atlassian.net) — PR pas encore créée |
| `~/src/LibreChat` | clone upstream + config **vivante** (yaml, override, .env) | AUCUN commit dans ce dépôt |
| ce dépôt | copies versionnées des configs + agent + prompts + outils viz + scripts de seed | main |

Documentation d'architecture/décisions : page Notion « Radiant LibreChat »
(espace Ferlab → Analyses). Elle fait foi pour l'historique des frictions,
la cible zone d'accueil (Bedrock+IAM, OBO, client Keycloak dédié) et le backlog
(mcp-ui pour fiche variant dans le chat, forçage des panneaux par URL).

## Règles de travail exigées par Vincent

1. **Implémenter → LE LAISSER TESTER → commit/push seulement après son feu vert
   explicite.** Jamais de push avant validation, même sur ce dépôt.
2. **Jamais de secret dans le chat ni dans git.** Vincent édite lui-même les
   `.env` ; ne jamais lire les `.env` du dépôt radiant-portal (son CLAUDE.md
   l'interdit). Les scripts forgent les jetons DANS le conteneur (JWT_SECRET
   n'en sort pas).
3. Commits radiant-portal : `type(scope): SJRA-#### message` — hook commitlint
   strict : sujet anglais **tout minuscule, SANS parenthèses** ; hook pre-push
   exige `npm install` à la racine du dépôt (pas seulement frontend/).
4. Flux de config LibreChat : modifier `~/src/LibreChat` (le vivant), tester,
   puis recopier ici (`librechat/`) au commit. Après toute modif d'agent/prompts
   dans Mongo : ré-exporter les JSON ici (voir scripts et agent/).

## Reprise sur une nouvelle machine

Suivre le README (« bootstrap scripté »). En plus, transférer **à la main** ce
qui ne voyage pas par git :

1. **Secrets** : `frontend/portals/radiant/.env` du portail (Keycloak qlin :
   realm `qlin`, client `radiant` + secret ; API_HOST de la zone) et `.env` de
   LibreChat (remplir depuis `librechat/.env.example` : OPENID_CLIENT_SECRET =
   même secret que le portail, ANTHROPIC_API_KEY).
2. **MongoDB ne se transfère pas** : recréer agent + questions avec
   `scripts/seed-agent.sh` et `scripts/seed-prompts.sh` (× fr/en). ⚠️ Le
   nouvel `agent_id` DOIT être reporté dans
   `apps/case/src/entity/layout/header.tsx` (constante `LIBRECHAT_AGENT_ID`)
   — actuel : `agent_aGiiW9fwwps-SDeE19maA` (invalide sur une nouvelle base).
3. Premier login LibreChat en SSO **dans un onglet** (Keycloak refuse l'iframe),
   puis « Authenticate » sur radiant (une fois — offline_access ensuite).
4. Réglages navigateur par utilisateur (à refaire) : Paramètres → Chat :
   auto-send prompts OFF, pensées/outils repliés.

## Pièges d'environnement (vécus, tous documentés au README + Notion)

- DNS intermittent sur `*.dev.qlin.aws.sante.quebec` (deux résolveurs sur les
  postes CHUSJ, un seul connaît la zone) → erreurs ENOTFOUND passagères,
  y compris au démarrage de LibreChat (SSO non enregistré → redémarrer).
- Keycloak zone : DCR refusé (Trusted Hosts) → client OAuth pré-configuré ;
  la zone a déjà eu une panne Keycloak (404 sur tous les realms) sans impact
  sur notre config.
- Après tout `docker compose restart api` : redémarrer `biomcp` et
  `radiant-tools` (namespace réseau partagé) ; les connexions MCP utilisateurs
  se réauthentifient à la première conversation.
- Instructions d'agent : EN ANGLAIS obligatoirement (sinon réponses en français
  même aux questions anglaises) ; règle de langue absolue en première ligne.
- `titlePrompt` : placeholder `{convo}` obligatoire ; `endpoints.all` remplace
  (ne fusionne pas) la config de titrage.
- API Anthropic : erreurs 529 « Overloaded » épisodiques sur Opus 5 → l'agent
  tourne sur `claude-opus-4-8` (bon compromis).

## Idées en réserve (discutées, non implémentées)

Prochains outils viz (pedigree, couverture, tableau ACMG) ; questions par
groupe linguistique (partage par groupes) quand il y aura plusieurs
utilisateurs ; filtre du tableau à l'arrivée d'un deep-link (question UX pour
les pilotes) ; BioMCP AlphaGenome (clé Google requise) ; texte de PR prêt dans
l'historique de conversation, à rafraîchir avec les features récentes.
