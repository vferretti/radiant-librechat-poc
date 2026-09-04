-- =====================================================================================
-- Radiant — collecte des variants d'un cas germinal (StarRocks)
-- Destination : outil du serveur MCP Radiant. Aucune écriture.
--
-- Périmètre : COLLECTE. Deux étages bien séparés :
--   1. RECEVABILITÉ — appel retenu, rareté populationnelle et rareté dans la cohorte interne.
--   2. SÉLECTION CLINIQUE — au moins un critère de candidature (requête 3), chacun exposé en
--      colonne `crit_*` pour qu'on sache lequel a fait entrer la ligne.
-- En revanche : AUCUN tri par pertinence, aucun score, aucune pondération, aucun rang.
-- L'ordre est `locus_id` (stable). Les colonnes qui servent à juger (Exomiser,
-- CADD/REVEL/SpliceAI, ClinVar, ACMG, qualité d'appel) sont retournées telles quelles.
--
-- CONVENTIONS DE PARAMÈTRES
--   ${tenant}    préfixe de base par tenant. Ce n'est PAS un paramètre lié : c'est un
--                identifiant SQL, donc interpolé. À valider côté serveur contre la liste
--                des bases autorisées (regex ^[a-z0-9_]+$ au minimum) — sinon injection.
--                Résoudre le tenant DEPUIS LA DONNÉE (requête 0), jamais depuis un prompt.
--   :case_id     entier
--   :seq_id      entier — séquençage du cas-index (requête 1)
--   :task_id     entier — voir requête 1b : ne pas le deviner
--   :af_max            fréquence populationnelle max         (ex. 0.01)
--   :cohort_af_max     fréquence max dans la cohorte interne, chez les NON ATTEINTS (ex. 0.01)
--   :min_cohort_n      effectif minimal de non atteints pour que cette fréquence soit
--                      opposable (ex. 50). En dessous, on ne disqualifie pas sur la cohorte.
--   :min_dp, :min_gq, :min_ad_ratio  seuils de qualité d'appel (ex. 10, 20, 0.20)
--
-- PIÈGES CONNUS (tous vécus)
--   * Interroger la base d'un AUTRE tenant renvoie 0 ligne SANS erreur — indistinguable de
--     « pas de donnée ». D'où la requête 0, obligatoire avant toute requête par tenant.
--   * `radiant.staging_sequencing_experiment` est PARTAGÉE (pas de tenant_code), clé case_id.
--   * La task qui produit les CNV n'est souvent PAS celle qui produit les SNV, et un cas
--     porte plusieurs task_id pour un même seq_id → requête 1b avant 3 et 4.
--   * `symbol` de germline__cnv__occurrence est un ARRAY de gènes chevauchés
--     (array_contains), tout comme clinvar_interpretation et omim_inheritance_code.
--   * Une recevabilité seule peut renvoyer des dizaines de milliers de lignes sur un WGS :
--     paginer avec `ORDER BY o.locus_id` (ordre stable) plutôt qu'un LIMIT sur un tri
--     partiel, qui rend le jeu retourné non reproductible en cas d'ex æquo.
-- =====================================================================================


-- -------------------------------------------------------------------------------------
-- 0. VALIDATION DU TENANT — obligatoire avant toute requête par tenant.
--    1 ligne = tenant confirmé. 0 ligne ou erreur « unknown database » = mauvais tenant
--    ou pas d'accès : ne JAMAIS conclure « pas de donnée pour ce cas ».
-- -------------------------------------------------------------------------------------
SELECT id, tenant_code
FROM ${tenant}_tenant.cases
WHERE id = :case_id;


-- -------------------------------------------------------------------------------------
-- 1. STRUCTURE FAMILIALE + IDENTIFIANTS SOUMETTEURS
--    LEFT JOIN volontaires : si une vue clinique n'est pas lisible avec les droits de
--    l'utilisateur (Ranger : masquage PII, row-filters), la ligne revient quand même et
--    seules les colonnes soumetteur sont nulles.
--    Afficher submitter_patient_id / submitter_sample_id ; les id internes servent aux
--    requêtes et aux liens profonds.
-- -------------------------------------------------------------------------------------
SELECT sse.seq_id,
       sse.task_id,
       sse.patient_id,
       sse.family_id,
       sse.family_role,          -- proband | mother | father
       sse.affected_status,
       sse.analysis_type,        -- germline | somatic
       p.submitter_patient_id,
       spl.submitter_sample_id,
       p.sex_code,
       p.date_of_birth
FROM radiant.staging_sequencing_experiment sse
LEFT JOIN ${tenant}_tenant.sequencing_experiment se ON se.id = sse.seq_id
LEFT JOIN ${tenant}_tenant.sample             spl ON spl.id = se.sample_id
LEFT JOIN ${tenant}_tenant.patient              p ON p.id   = spl.patient_id
WHERE sse.case_id = :case_id
ORDER BY sse.family_role, sse.seq_id, sse.task_id;


-- -------------------------------------------------------------------------------------
-- 1b. QUELLE PAIRE (seq_id, task_id) PORTE QUOI  ← remplace la « cascade d'élargissement »
--     Un cas porte plusieurs tasks par séquençage et les SNV/CNV ne sont pas toujours sur
--     la même. Au lieu de deviner puis d'élargir en cas de 0 ligne, on demande d'abord où
--     est la donnée, et on choisit la paire qui en a.
-- -------------------------------------------------------------------------------------
SELECT sse.family_role, sse.seq_id, sse.task_id, 'snv' AS payload, COUNT(*) AS n
FROM radiant.staging_sequencing_experiment sse
JOIN ${tenant}_tenant.germline__snv__occurrence o
     ON o.seq_id = sse.seq_id AND o.task_id = sse.task_id
WHERE sse.case_id = :case_id
GROUP BY sse.family_role, sse.seq_id, sse.task_id
UNION ALL
SELECT sse.family_role, sse.seq_id, sse.task_id, 'cnv' AS payload, COUNT(*) AS n
FROM radiant.staging_sequencing_experiment sse
JOIN ${tenant}_tenant.germline__cnv__occurrence c
     ON c.seq_id = sse.seq_id AND c.task_id = sse.task_id
WHERE sse.case_id = :case_id
GROUP BY sse.family_role, sse.seq_id, sse.task_id
ORDER BY family_role, seq_id, task_id, payload;


-- -------------------------------------------------------------------------------------
-- 2. PHÉNOTYPES HPO OBSERVÉS (positifs)
-- -------------------------------------------------------------------------------------
SELECT o.code_value AS hpo_id, h.name AS hpo_name, o.patient_id
FROM ${tenant}_tenant.obs_categorical o
LEFT JOIN radiant.hpo_term h ON h.id = o.code_value
WHERE o.case_id = :case_id
  AND o.observation_code   = 'phenotype'
  AND o.interpretation_code = 'positive'
ORDER BY o.code_value;


-- -------------------------------------------------------------------------------------
-- 2b. GÈNES DES PANELS HPO DU CAS (utile en jointure, ou seul pour le contexte)
-- -------------------------------------------------------------------------------------
SELECT DISTINCT gp.symbol
FROM radiant.hpo_gene_panel gp
JOIN ${tenant}_tenant.obs_categorical ob ON gp.hpo_term_id = ob.code_value
WHERE ob.case_id = :case_id
  AND ob.observation_code    = 'phenotype'
  AND ob.interpretation_code = 'positive'
ORDER BY gp.symbol;


-- -------------------------------------------------------------------------------------
-- 3. SNV / INDELS DU CAS-INDEX — recevabilité, puis candidature clinique.
--
--    ÉTAGE 1, recevabilité (WHERE de la CTE) : appel retenu, rareté populationnelle, rareté
--    dans la cohorte interne. La qualité d'appel n'y est PAS : elle est retournée avec un
--    drapeau `call_flag`, parce qu'un appel douteux doit être signalé, pas caché. Pour
--    l'exclure quand même :  AND o.dp >= :min_dp AND o.gq >= :min_gq
--                            AND o.ad_ratio >= :min_ad_ratio
--
--    ÉTAGE 2, candidature (WHERE final) : au moins un `crit_*` vrai. Ce n'est pas un tri —
--    c'est la définition de « variant à regarder », et elle se discute critère par critère
--    avec les généticiens. Chaque condition est renvoyée en colonne, donc une ligne ne peut
--    pas être présente pour une raison qu'on ne voit pas. Pour désactiver un critère, le
--    retirer du WHERE final (ou le passer en paramètre booléen côté outil).
--
--    Cohorte interne : `germline_pf_wgs_not_affected` plutôt que l'agrégat
--    `germline_pf_wgs` — un variant fréquent chez les ATTEINTS n'est pas disqualifiant.
--    Basculer sur les colonnes `_wxs` pour un panel/exome. (Vérifier les noms exacts sur
--    votre version du modèle.)
-- -------------------------------------------------------------------------------------
WITH hpo AS (
    -- gènes des panels HPO du cas
    SELECT DISTINCT gp.symbol
    FROM radiant.hpo_gene_panel gp
    JOIN ${tenant}_tenant.obs_categorical ob ON gp.hpo_term_id = ob.code_value
    WHERE ob.case_id = :case_id
      AND ob.observation_code    = 'phenotype'
      AND ob.interpretation_code = 'positive'
),
hist AS (
    -- loci déjà interprétés par un généticien du tenant, sur d'AUTRES cas.
    -- Pour ne retenir que pathogénique / probablement pathogénique, filtrer `classification`
    -- sur les codes LOINC du formulaire : 'LA6668-3' et 'LA26332-9'.
    SELECT DISTINCT locus_id
    FROM ${tenant}_tenant.interpretation_germline
    WHERE case_id <> :case_id
),
cand AS (
    SELECT
        -- clés (locus_id sert aussi aux liens profonds du portail)
        o.locus_id, o.seq_id, o.task_id,
        -- identification du variant
        v.symbol, v.hgvsg, v.hgvsp, v.chromosome, v.consequences, v.vep_impact,
        -- génotype et trio
        o.zygosity, o.father_zygosity, o.mother_zygosity,
        o.transmission_mode,      -- autosomal_dominant_de_novo | autosomal_recessive | NULL
        o.parental_origin,        -- father | mother | NULL
        -- qualité de l'appel (retournée, non filtrante)
        o.filter, o.dp, o.gq, o.ad_ratio,
        (o.dp < :min_dp OR o.gq < :min_gq OR o.ad_ratio < :min_ad_ratio) AS call_flag,
        -- fréquences
        v.gnomad_v3_af,
        v.germline_pf_wgs, v.germline_pf_wgs_affected, v.germline_pf_wgs_not_affected,
        -- porteurs / effectif, pour rendre « fréq (porteurs/total) » et juger la fiabilité
        v.germline_pc_wgs_not_affected, v.germline_pn_wgs_not_affected,
        -- preuve établie
        v.clinvar_interpretation,     -- ARRAY
        v.omim_inheritance_code,      -- ARRAY : AD | AR | XL ...
        -- annotations du pipeline (faits, pas des verdicts)
        o.exomiser_variant_score, o.exomiser_gene_combined_score, o.exomiser_moi,
        o.exomiser_acmg_classification, o.exomiser_acmg_evidence,  -- ARRAY de codes ACMG
        -- in-silico (conséquence retenue)
        c.cadd_phred, c.revel_score, c.spliceai_ds, c.spliceai_type,
        c.gnomad_pli, c.gnomad_loeuf,
        -- ---- critères de candidature, chacun visible ----
        (array_contains(v.clinvar_interpretation, 'Pathogenic')
         OR array_contains(v.clinvar_interpretation, 'Likely_pathogenic'))  AS crit_clinvar,
        (o.transmission_mode IN ('autosomal_dominant_de_novo',
                                 'autosomal_recessive'))                    AS crit_transmission,
        (v.vep_impact IN ('HIGH', 'MODERATE'))                              AS crit_impact,
        (h.symbol IS NOT NULL)                                              AS crit_hpo_panel,
        (ig.locus_id IS NOT NULL)                                           AS crit_tenant_history
    FROM ${tenant}_tenant.germline__snv__occurrence o
    JOIN ${tenant}_tenant.snv__variant v
         ON v.locus_id = o.locus_id
    LEFT JOIN radiant.snv__consequence c
         ON c.locus_id = o.locus_id AND c.is_picked = true
    LEFT JOIN hpo  h  ON h.symbol   = v.symbol
    LEFT JOIN hist ig ON ig.locus_id = o.locus_id
    WHERE o.seq_id  = :seq_id
      AND o.task_id = :task_id
      AND o.filter  = 'PASS'
      AND (v.gnomad_v3_af IS NULL OR v.gnomad_v3_af < :af_max)
      -- Cohorte interne : ne disqualifier que si l'effectif des non atteints permet de
      -- l'affirmer. Sans ce garde-fou, un seul porteur parmi peu de non atteints produit
      -- une fréquence apparente élevée et écarte un vrai candidat.
      AND (v.germline_pf_wgs_not_affected IS NULL
           OR v.germline_pn_wgs_not_affected IS NULL
           OR v.germline_pn_wgs_not_affected < :min_cohort_n
           OR v.germline_pf_wgs_not_affected < :cohort_af_max)
)
SELECT *
FROM cand
WHERE crit_clinvar
   OR crit_transmission
   OR crit_impact
   OR crit_hpo_panel
   OR crit_tenant_history
ORDER BY locus_id;


-- -------------------------------------------------------------------------------------
-- 4. HÉTÉROZYGOTES COMPOSÉS — agrégation par GÈNE.
--    Un composite se définit au niveau du gène : deux variants rares en trans, un de
--    chaque parent, dont aucun n'est individuellement remarquable. Aucun WHERE par ligne
--    ne peut l'exprimer, d'où cette requête séparée.
--    NB : Exomiser trouve aussi les composites SNV-SNV (mode récessif) ; cette requête
--    reste utile parce qu'elle donne les DEUX locus, ce que son classement par gène ne
--    donne pas.
-- -------------------------------------------------------------------------------------
SELECT v.symbol,
       COUNT(*)                                                        AS n_variants,
       MAX(CASE WHEN o.parental_origin = 'father' THEN 1 ELSE 0 END)   AS has_paternal,
       MAX(CASE WHEN o.parental_origin = 'mother' THEN 1 ELSE 0 END)   AS has_maternal,
       ARRAY_AGG(o.locus_id)                                           AS locus_ids,
       ARRAY_AGG(v.hgvsp)                                              AS hgvsp_list
FROM ${tenant}_tenant.germline__snv__occurrence o
JOIN ${tenant}_tenant.snv__variant v ON v.locus_id = o.locus_id
WHERE o.seq_id  = :seq_id
  AND o.task_id = :task_id
  AND o.filter  = 'PASS'
  AND o.zygosity = 'HET'
  AND (v.gnomad_v3_af IS NULL OR v.gnomad_v3_af < :af_max)
GROUP BY v.symbol
HAVING COUNT(*) >= 2
   AND MAX(CASE WHEN o.parental_origin = 'father' THEN 1 ELSE 0 END) = 1
   AND MAX(CASE WHEN o.parental_origin = 'mother' THEN 1 ELSE 0 END) = 1
ORDER BY v.symbol;


-- -------------------------------------------------------------------------------------
-- 5. CNV DE TOUTE LA FAMILLE — une seule requête, pas de cascade.
--    Passer par la table partagée couvre toutes les paires (seq_id, task_id) du cas, ce
--    qui neutralise le problème d'appariement seq/task. `family_role` permet de déduire
--    le statut de novo en comparant les intervalles du cas-index à ceux des parents
--    (aucune colonne ne le donne).
-- -------------------------------------------------------------------------------------
SELECT sse.family_role, sse.affected_status,
       c.seq_id, c.task_id, c.cnv_id, c.part,
       c.chromosome, c.start, c.end, c.length, c.cytoband,
       c.type, c.svtype, c.cn, c.bc, c.sm, c.calls,
       c.quality, c.filter,
       c.symbol,                 -- ARRAY des gènes chevauchés
       c.nb_genes, c.nb_snv,
       c.gnomad_af, c.gnomad_sf, c.gnomad_sc, c.gnomad_sn,
       c.gnomad_sc_hom, c.gnomad_sc_het
FROM ${tenant}_tenant.germline__cnv__occurrence c
JOIN radiant.staging_sequencing_experiment sse
     ON sse.seq_id = c.seq_id AND sse.task_id = c.task_id
WHERE sse.case_id = :case_id
  AND c.filter = 'PASS'
  AND (c.gnomad_sf IS NULL OR c.gnomad_sf < :af_max)
ORDER BY sse.family_role, c.chromosome, c.start;


-- -------------------------------------------------------------------------------------
-- 6. SECOND HIT SNV + CNV — délétion sur un allèle, SNV rare hétérozygote sur l'autre.
--    Seul diagnostic récessif qu'Exomiser ne peut atteindre d'aucune façon : il tourne
--    sur les appels de petits variants et ne reçoit pas les CNV.
--    Le chevauchement est établi par le gène (ARRAY `symbol` du CNV), pas par les
--    coordonnées : suffisant ici, et robuste aux bornes d'exons.
-- -------------------------------------------------------------------------------------
SELECT v.symbol,
       o.locus_id, v.hgvsg, v.hgvsp, o.zygosity, o.parental_origin,
       v.gnomad_v3_af, v.omim_inheritance_code,
       c.cnv_id, c.type, c.chromosome, c.start, c.end, c.length, c.cn, c.gnomad_sf,
       c.seq_id AS cnv_seq_id, c.task_id AS cnv_task_id
FROM ${tenant}_tenant.germline__snv__occurrence o
JOIN ${tenant}_tenant.snv__variant v
     ON v.locus_id = o.locus_id
JOIN ${tenant}_tenant.germline__cnv__occurrence c
     ON array_contains(c.symbol, v.symbol)
JOIN radiant.staging_sequencing_experiment sse_snv
     ON sse_snv.seq_id = o.seq_id AND sse_snv.task_id = o.task_id
JOIN radiant.staging_sequencing_experiment sse_cnv
     ON sse_cnv.seq_id = c.seq_id AND sse_cnv.task_id = c.task_id
WHERE sse_snv.case_id = :case_id AND sse_snv.family_role = 'proband'
  AND sse_cnv.case_id = :case_id AND sse_cnv.family_role = 'proband'
  AND o.filter = 'PASS' AND o.zygosity = 'HET'
  AND (v.gnomad_v3_af IS NULL OR v.gnomad_v3_af < :af_max)
  AND c.filter = 'PASS' AND c.type = 'DEL'
ORDER BY v.symbol, o.locus_id;


-- -------------------------------------------------------------------------------------
-- 7. HISTORIQUE D'INTERPRÉTATION DU TENANT, pour tous les loci du cas d'un coup.
--    Un locus déjà classé par un généticien du tenant est une information que ne porte
--    aucun algorithme. Version ensembliste : évite un aller-retour par locus.
-- -------------------------------------------------------------------------------------
SELECT ig.locus_id,
       ig.classification,
       COUNT(DISTINCT ig.case_id) AS n_cases
FROM ${tenant}_tenant.interpretation_germline ig
WHERE ig.locus_id IN (
        SELECT DISTINCT o.locus_id
        FROM ${tenant}_tenant.germline__snv__occurrence o
        WHERE o.seq_id = :seq_id AND o.task_id = :task_id AND o.filter = 'PASS')
  AND ig.case_id <> :case_id          -- l'historique des AUTRES cas
GROUP BY ig.locus_id, ig.classification
ORDER BY ig.locus_id, ig.classification;


-- -------------------------------------------------------------------------------------
-- 8. CLASSEMENT EXOMISER DU SÉQUENÇAGE — lecture directe, par gène.
--    Retourné tel quel : c'est une donnée du pipeline, pas un calcul à refaire.
--    `moi` porte le mode de transmission retenu (dont récessif composite).
-- -------------------------------------------------------------------------------------
SELECT rank, symbol, moi, gene_combined_score, variant_score, acmg_classification
FROM ${tenant}_tenant.exomiser
WHERE seq_id = :seq_id
ORDER BY rank;


-- =====================================================================================
-- NOTES POUR L'OUTIL MCP
--
-- * Résoudre le tenant côté serveur (case_id + appartenances de l'utilisateur) plutôt que
--   de le recevoir en paramètre : un préfixe de tenant qui voyage dans un prompt est une
--   donnée de configuration déguisée, et une erreur y est silencieuse (0 ligne, pas
--   d'erreur).
-- * Conserver l'identité de l'utilisateur de bout en bout (OAuth / OBO) : l'autorisation
--   est appliquée par Ranger AU NIVEAU DES DONNÉES (rôles de tenant, masquage PII,
--   row-filters). Aucun compte de service.
-- * Ne jamais exposer `task_id` dans une sortie destinée à un clinicien : concept de
--   pipeline inconnu des généticiens. Il reste dans les requêtes et les liens profonds.
-- * Les cinq `crit_*` de la requête 3 ramènent le volume à quelques dizaines de lignes sur
--   un trio. Ils sont une SÉLECTION, pas un tri : les exposer en paramètres booléens de
--   l'outil (activés par défaut) plutôt que de les figer, et toujours les renvoyer en
--   colonnes — une ligne ne doit jamais être présente pour une raison invisible. Prévoir
--   quand même un COUNT et une pagination sur `locus_id` si tous les critères sont
--   désactivés.
-- * Le filtre de cohorte interne n'est pas un simple élargissement de ce que fait
--   l'agent LibreChat (qui filtre sur l'agrégat `germline_pf_wgs`) : il cible dans les
--   deux sens. Un variant enrichi chez les ATTEINTS — variant fondateur local — n'est plus
--   exclu à tort ; un variant fréquent chez les NON ATTEINTS — artefact ou polymorphisme
--   régional — est mieux écarté. Le garde-fou `:min_cohort_n` empêche une petite cohorte
--   de non atteints de disqualifier sur du bruit ; à relever au fur et à mesure que la
--   cohorte grandit. Vérifier les noms exacts des colonnes `germline_pc_wgs_*` /
--   `germline_pn_wgs_*` sur votre version du modèle (équivalents `_wxs` pour panel/exome).
-- * `crit_tenant_history` est nouveau par rapport à ce que fait l'agent LibreChat
--   aujourd'hui : un locus déjà interprété dans le tenant entrait jusqu'ici seulement s'il
--   satisfaisait un autre critère, et pouvait donc être coupé.
-- * Liens profonds vers la fiche d'occurrence du portail :
--   /case/entity/<case_id>?tab=variants&seq_id=<seq_id>&task_id=<task_id>&selectedVariant=<locus_id>
-- =====================================================================================
