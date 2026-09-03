# CLAUDE.md — POC assistant IA Radiant × LibreChat

Contexte pour Claude Code (et tout repreneur) : ce dépôt est la source de vérité
d'une POC fonctionnelle de bout en bout. Lire ce fichier puis le README avant d'agir.

## Vue d'ensemble (état : fonctionnel, 2026-09-03)

Bouton « Analyser avec l'IA » dans la page Case du portail Radiant → LibreChat en
modale (choix : nouvelle analyse / reprendre l'historique) → agent « IA Radiant »
branché à 3 serveurs MCP : `radiant` (StarRocks via OAuth Keycloak **par
utilisateur** → droits Apache Ranger individuels), `biomcp` (littérature
PubMed/PubTator, MyVariant), `viz` (bibliothèque maison : Venn trio/duo).
Bilingue FR/EN de bout en bout. Titres de conversation « Case <n> Analysis ».
Liens variants → fiche occurrence du portail (deep-link corrigé côté portail).

Ce que l'agent sait faire (tout est dans ses instructions, `agent/assistant-radiant.json`) :
résumé clinique du case (identifiants **soumetteurs**, pas les id internes) · priorisation SNV en
**quatre couches** (recevabilité, cohérence génotype-phénotype, preuve établie, in-silico en
départage) avec requête **hétérozygotes composés** distincte · **CNV systématiques** (second hit,
de novo) · **fiche d'occurrence** compacte en 8 blocs à parité avec le panneau du portail ·
**diagramme de Venn** familial · littérature BioMCP · **proposition d'interprétation** germinale
(formulaire du portail pré-rempli, aucune écriture).

Quatre emplacements de travail :

| Où | Quoi | Git |
|---|---|---|
| `~/src/radiant-portal` | frontend (bouton, modale, deep-link) | branche `feat/SJRA-1835-assistant-ia` (ticket SJRA-1835, Jira d3b.atlassian.net) — PR pas encore créée |
| `~/src/LibreChat` | clone upstream + config **vivante** (yaml, override, .env) | AUCUN commit dans ce dépôt |
| ce dépôt | copies versionnées des configs + agent + prompts + outils viz + scripts de seed | main |
| `~/src/radiant-maquette` | maquettes HTML statiques (onglet Aperçu = `dashboard/`, QC, prescription, HPO) — carte IA du dashboard | main |

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
   ⚠️ **Les deux scripts sont cassés en l'état** (2026-09-01, non corrigés) :
   `._id.str` renvoie une chaîne vide dans les mongosh récents, et LibreChat
   refuse toute requête sans User-Agent de navigateur (middleware `uaParser`
   → « Illegal request »). Recette qui marche, à répéter pour chaque fichier :
   ```bash
   UID=$(docker exec chat-mongodb mongosh LibreChat --quiet \
     --eval 'print(db.users.findOne({},{_id:1})._id.toString())')
   TOKEN=$(docker exec LibreChat node -e "require('dotenv').config({path:'/app/.env'}); \
     console.log(require('jsonwebtoken').sign({id:'$UID'}, process.env.JWT_SECRET, {expiresIn:'10m'}))")
   UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36'
   # agent
   curl -s -X POST http://localhost:3080/api/agents -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: application/json' -H "User-Agent: $UA" -d @agent/assistant-radiant.json
   # questions (une par ligne du JSON)
   jq -c '.[]' prompts/questions-fr.json | while read -r q; do curl -s -X POST \
     http://localhost:3080/api/prompts -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: application/json' -H "User-Agent: $UA" -d "$q"; done
   ```
   **Itérer ensuite sur les instructions** (le flux de toute la session) : éditer
   `agent/assistant-radiant.json`, puis `PATCH /api/agents/<agent_id>` avec
   `{"instructions": "…"}`, même jeton et même User-Agent ; vérifier que le
   dépôt et Mongo sont identiques avant de commiter.
   ⚠️ Deux questions créées à la main par Vincent ne sont **pas** dans le dépôt
   (« Variants prioritaires », « Diagramme de venn ») : elles seront perdues.
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
- **Jamais de code tenant littéral dans les instructions.** Le préfixe était codé
  en dur (`radiant_tenant.`) : pour un case d'un autre tenant, StarRocks renvoie
  **0 ligne sans erreur** — indistinguable de « pas de donnée ». L'agent valide
  désormais le tenant sur la donnée (`SELECT id, tenant_code FROM
  <tenant>_tenant.cases WHERE id=N`) et n'a plus le droit de deviner. Les cases
  de test de Vincent sont dans le tenant **`pragmatiq`**, pas `radiant`.
- Toute écriture via l'API LibreChat exige un **User-Agent de navigateur**
  (middleware `uaParser` → « Illegal request ») ; et `._id.str` renvoie vide dans
  les mongosh récents (utiliser `._id.toString()`). Voir la recette plus haut.
- Le conteneur `rag_api` boucle en redémarrage (`OPENAI_API_KEY` absente) :
  **sans impact**, la POC ne l'utilise pas.
- **Appariement seq/task défaillant** : la task qui produit les CNV n'est souvent
  pas celle qui produit les SNV. Contournement dans les instructions (cascade
  d'élargissement) ; à corriger côté données. Et **ne jamais nommer les tasks**
  dans une réponse : concept de pipeline inconnu des généticiens.
- `titlePrompt` : placeholder `{convo}` obligatoire ; `endpoints.all` remplace
  (ne fusionne pas) la config de titrage.
- API Anthropic : erreurs 529 « Overloaded » épisodiques sur Opus 5 → l'agent
  tourne sur `claude-opus-4-8` (bon compromis).

## Chantier en attente : rapports cliniques par gabarit

**Statut : toujours en attente du gabarit + de la bibliothèque d'énoncés
(Vincent les a demandés).** Stratégie complétée le 2026-09-02 (détail dans Notion) :
le rapport est une **projection de l'interprétation enregistrée**, jamais une
nouvelle inférence — il lit `interpretation_germline` et n'écrit rien qui ne soit
pas déjà dans le dossier (`[à compléter]` sinon). Le **rendu est une fonction pure**
de ses entrées, donc il peut vivre dans le MCP `viz` local (`docxtpl` sur le `.docx`
réel du labo, PDF par conversion) alors que la **collecte** ne peut pas (OAuth par
utilisateur, Ranger). Dès que le gabarit arrive, l'étape 1 — sections rendues en
Markdown dans la conversation — est faisable dans la journée.

Approche retenue lors de la discussion du 2026-08-20 :

- **Trois pièces distinctes** : (1) le *gabarit* = structure rédactionnelle
  (prompt sauvegardé si 2-5 gabarits ; outil `get_report_template` servant des
  fichiers versionnés si multi-gabarits/traçabilité clinique) ; (2) la collecte
  = les outils MCP existants (`read_query`, `article_searcher`) ; (3) le rendu
  = Markdown dans la conversation d'abord, outil `render_report` (.docx via
  python-docx dans la biblio viz) seulement quand le fond est stabilisé.
- **Bibliothèque d'énoncés pré-définis** (les généticiens sélectionnent des
  textes approuvés, ils ne rédigent pas) : **doit vivre dans un outil MCP adossé
  à une source de données**, pas dans le prompt (volume, gouvernance, verbatim
  garanti). Stockage cible : table PostgreSQL du portail avec UI d'admin (ou
  fichiers YAML versionnés pour la POC). **Vérifier d'abord si Radiant a déjà
  des énoncés structurés** (tables `interpretation_germline`/`_somatic`,
  dialogue d'interprétation) — s'y greffer plutôt que créer un silo.
  Modèle d'énoncé : `id, section, category, language, text avec {{placeholders}},
  version, approved_by/on`. Les placeholders sont remplis depuis les données de
  l'occurrence → le texte reste approuvé mot pour mot.
- **Rôle de l'agent = proposer, pas rédiger** : collecte → `search_report_statements(section)`
  → propose 2-3 énoncés justifiés par section → le généticien choisit →
  assemblage **verbatim**, sections sans énoncé marquées `[à compléter]`.
- **Agent dédié** « Rapport clinique » (séparé de « IA Radiant ») : instructions
  de nature différente, effort de raisonnement plus élevé, garde-fous stricts
  (rien d'inventé, chaque affirmation traçable à une requête ou un PMID, mention
  de brouillon non validé dans le gabarit, aucune PII vers BioMCP, annexe des
  requêtes exécutées pour l'auditabilité).
- **Démarrage recommandé** : UNE section (ex. conclusion d'interprétation),
  10-15 énoncés en YAML dans ce dépôt, outil de recherche, validation du patron
  par les généticiens AVANT d'investir dans la table PostgreSQL et l'UI.
- Questions ouvertes à poser aux généticiens : les énoncés existent-ils déjà
  sous forme structurée (Word partagé, autre logiciel, table) ? Sont-ils
  bilingues (sinon, prévoir FR/EN comme pour les questions sauvegardées) ?

## Backlog : écriture dans le dossier (drapeaux, interprétation)

Discuté le 2026-08-26. Passage de « assistant qui consulte » à « assistant qui
prépare des actes cliniques » — à ne pas implémenter à la légère.

**Verrou technique commun** : l'agent n'a que des outils de lecture
(`write_query` retiré volontairement), et de toute façon les écritures ne
doivent PAS passer par StarRocks/le catalogue fédéré mais par **l'API REST du
portail** (qui porte ses propres autorisations et la traçabilité). Un outil MCP
d'écriture doit donc relayer vers l'API avec le **JWT de l'utilisateur**
(en-tête `{{LIBRECHAT_USER_*}}` ou OBO), jamais avec un compte de service.

1. **Drapeaux d'occurrence** (« marque ce variant d'un drapeau »). Table
   `occurrence_flag`, `flag_type` ∈ **`flag` / `pin` / `star`** (ce ne sont pas
   des couleurs). Outil cible : `set_occurrence_flag(case_id, seq_id, locus_id,
   flag_type)` dans le MCP Radiant officiel. Exiger une **confirmation
   explicite par appel** (LibreChat sait imposer l'approbation par outil).
2. **Formulaire d'interprétation** (pré-remplissage, surtout les publications).
   Le modèle s'y prête très bien (`InterpretationGermline` :
   `pubmed[]{citation_id, citation}`, `classification`,
   `classification_criterias[]`, `transmission_modes[]`, `condition`,
   `interpretation`). **MAIS** `created_by`/`updated_by` font de
   l'enregistrement un acte signé : l'IA ne doit jamais écrire sous l'identité
   du généticien.
   - **Étape 1 : FAITE le 2026-09-01** (mode « proposition d'interprétation » dans
     les instructions ; valeurs exactes du formulaire du portail — 5 codes LOINC,
     28 critères ACMG, 12 modes de transmission, `citation_id` en chiffres seuls ;
     protocole de sélection des publications pour éviter la dérive entre deux
     exécutions). Reste l'étape 2. Formulation d'origine : l'agent produit une
     proposition structurée (PMID + critères + texte candidat) que le
     généticien copie dans le formulaire. À faire en même temps que le chantier
     « rapports cliniques » — mêmes garde-fous, même gabarit.
   - **Étape 2 (cible, avec l'équipe Radiant)** : outil
     `propose_interpretation(...)` écrivant un **brouillon** (statut distinct,
     attribué à l'assistant), que le formulaire affiche comme suggestion à
     accepter/refuser champ par champ ; c'est le clic du généticien qui écrit.
     Demande un ajout au modèle de données (notion de brouillon/proposition,
     inexistante aujourd'hui) et à l'UI du portail.

## Chantier ouvert : carte IA du dashboard (2026-09-02 → 09-03)

Nouvel onglet « Aperçu » de la page Case (maquette : `~/src/radiant-maquette/dashboard/`,
son `CLAUDE.md` décrit l'état exact). Cartes retenues pour la V1 : **Cas**, **Activités**
(variants + commentaire), **priorisation** et la **carte IA**. Retirées : boîte de question
libre, contrôle qualité, rapports, ClinVar. **Phenovar et Franklin ne seront pas disponibles**
— la matrice de priorisation a donc deux colonnes : **Exomiser** (rang + `exomiser_variant_score`)
et **Radiant** (rang seul, la pondération n'étant pas validée).

Décisions structurantes (stratégie complète dans Notion) :

- **Séparer le calcul du récit** : la sélection est du **SQL versionné côté backend du
  portail**, le modèle ne rédige que la synthèse. Preuve que c'est nécessaire : deux
  exécutions de la même question à trois minutes d'écart ont donné des périmètres et des
  filtres différents.
- **Inférence dans le backend**, pas dans le navigateur : `GET /cases/{id}/ai-insight` +
  `POST …/refresh`, Bedrock avec rôle IAM en zone, aucun détour par le MCP.
- **Cache par empreinte des entrées** (données du case, version du prompt, modèle), pas par
  durée de validité : une ingestion ou une interprétation invalide la carte automatiquement,
  et une carte périmée le dit au lieu de mentir. Verrou par empreinte contre les générations
  concurrentes.
- **Aucune donnée identifiante dans la carte** → cache partageable par `(tenant, case_id)` ;
  l'API vérifie quand même l'accès au case avant de servir.
- **Explications = codes, pas de prose** : la requête expose ses conditions en colonnes, une
  seule table de règles produit **le score et les codes** (impossible qu'un variant soit classé
  pour une raison non affichée) ; l'API renvoie `crits:[{c:'de_novo'},{c:'impact',v:'HIGH'}…]`
  et l'interface traduit via l'i18n.

**À trancher avant de spécifier aux développeurs** (Vincent a arrêté la session ici) :

1. **Règles d'affichage des critères** — la liste complète des codes existe (couches 1 à 4 :
   rareté et exclusions, cohérence génotype-phénotype, preuve établie, départage) mais n'est
   pas figée : combien de pastilles par ligne, jeu fixe ou variable, traitement visuel des
   trois natures (positif · déclassement · exclusion). La maquette est encore hétérogène sur
   ce point, c'est le prochain sujet.
2. **Seuils et pondération** des quatre couches (1 % gnomAD, 1 % cohorte interne, poids
   relatifs) → à valider par les généticiens avant de les couler dans le backend.
3. **Données de démo incohérentes** dans la maquette : « Activités » et le commentaire parlent
   de BRCA1/TP53/MLH1 alors que le cas est un RGDI et que la priorisation parle de
   SCN1A/STXBP1 — hérité du POC, à nettoyer avant de montrer aux généticiens.

## Idées en réserve (discutées, non implémentées)

Prochains outils viz (pedigree, couverture, tableau ACMG) ; questions par
groupe linguistique (partage par groupes) quand il y aura plusieurs
utilisateurs ; filtre du tableau à l'arrivée d'un deep-link (question UX pour
les pilotes) ; BioMCP AlphaGenome (clé Google requise) ; texte de PR prêt dans
l'historique de conversation, à rafraîchir avec les features récentes.
