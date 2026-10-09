-- =============================================================================
-- GerMoonBank (GMB) · supabase/gmb_installation_complete.sql
-- INSTALLATION NEUVE, EN UN SEUL FICHIER : la base réelle complète (schéma, fonctions,
-- sécurité, données de référence) puis le mode développement (règles d'accès en pause).
-- Contenu identique aux 8 parties de supabase/installation/, mises bout à bout.
-- Depuis le SQL Editor : utilisez plutôt les 8 parties, une par une, ou la page
-- installation-base-gmb.html. Depuis un ordinateur : psql "<connexion>" -f gmb_installation_complete.sql
-- La partie 1 remet la base à zéro : installation neuve uniquement.
-- Base déjà installée : exécutez gmb_mise_a_niveau.sql, jamais ce fichier.
-- =============================================================================

-- GerMoonBank · installation de la base, partie 1 sur 8
-- Exécutez les parties dans l'ordre, chacune dans une requête vide du SQL Editor.
-- Contenu : 01_fondations, 02_tables
-- =============================================================================
-- GerMoonBank (GMB) · supabase/gmb_schema.sql
-- Base de données de GerMoonBank — cahier des charges v2.1, version 3
-- -----------------------------------------------------------------------------
-- Projet     : Supabase « Version 1.0 », région UE (Irlande), PostgreSQL 15+.
-- Exécution  : Supabase › SQL Editor, en plusieurs parties (supabase/installation/) depuis
--              un téléphone, ou en une seule fois depuis un ordinateur.
-- Rejouable  : oui. ATTENTION : rejouer le script efface toutes les données GMB
--              (les tables sont recréées).
-- Données    : base vide à l'installation. Seules les données de référence sont
--              chargées : formules, taux, catégories, modèles de messages, rôles du
--              back-office, paramètres de sécurité et état des services.
-- Sécurité   : règle du projet pendant le développement : aucune RLS. Les règles
--              d'accès sont enregistrées mais inactives ; gmb_mode_production.sql
--              les active à la fin du projet. Les écritures sensibles passent par des
--              fonctions contrôlées. La clé « secret » / « service_role » ne doit
--              JAMAIS apparaître dans le dépôt GitHub ni dans le navigateur.
-- Sommaire   :  0. Réinitialisation          1. Extensions, schémas, utilitaires
--               2. Référentiel et catalogue   3. CMS et état des services
--               4. Prospects et dossiers      5. Clients, comptes, paiements
--               6. Pro                        7. Business
--               8. Jeunes                     9. Back-office
--              10. Fonctions d'accès         11. Fonctions métier (RPC)
--              12. Déclencheurs              13. Vues
--              14. Sécurité (RLS, droits, stockage)
--              15. Données de référence et administration
--              16 à 29. Fonctions des lots suivants (placées après la section 11)
-- =============================================================================


-- =============================================================================
-- 0. RÉINITIALISATION
-- Supprime uniquement les objets GMB d'une exécution précédente : tables et
-- vues dont le commentaire commence par « GMB », fonctions public.gmb_* et
-- schéma gmb_prive. Les autres objets du projet ne sont pas touchés.
-- =============================================================================
do $$
declare r record;
begin
  for r in select c.oid::regclass as obj from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind = 'v' and obj_description(c.oid, 'pg_class') like 'GMB%' loop
    execute 'drop view if exists ' || r.obj || ' cascade';
  end loop;
  for r in select c.oid::regclass as obj from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind = 'r' and obj_description(c.oid, 'pg_class') like 'GMB%' loop
    execute 'drop table if exists ' || r.obj || ' cascade';
  end loop;
  for r in select p.oid::regprocedure as obj from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'gmb\_%' loop
    execute 'drop function if exists ' || r.obj || ' cascade';
  end loop;
end $$;

drop schema if exists gmb_prive cascade;


-- =============================================================================
-- 1. EXTENSIONS, SCHÉMAS ET UTILITAIRES
-- =============================================================================
create extension if not exists pgcrypto with schema extensions;
create extension if not exists citext with schema extensions;

-- Schéma interne : jamais exposé par l'API (codes secrets, grilles du clavier,
-- compteurs). Seules les fonctions contrôlées y accèdent.
create schema gmb_prive;
comment on schema gmb_prive is 'GMB : objets internes non exposés par l''API (codes, grilles du clavier, compteurs).';
revoke all on schema gmb_prive from public;
grant usage on schema gmb_prive to anon, authenticated, service_role;

-- Numérotation des références visibles par les clients
create sequence gmb_prive.seq_ouverture start 1;  -- GMB-OUV-AA-NNNNNN
create sequence gmb_prive.seq_credit    start 1;  -- GMB-CRE-AA-NNNNNN
create sequence gmb_prive.seq_demande   start 1;      -- GMB-DEM-AA-NNNNNN
create sequence gmb_prive.seq_reclam    start 1;      -- GMB-REC-AA-NNNNNN

-- Horodatage automatique des mises à jour
create or replace function gmb_prive.maj_horodatage() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- Référence lisible : GMB-OUV-26-048173
create or replace function gmb_prive.reference(p_prefixe text) returns text
language plpgsql volatile security definer set search_path = '' as $$
declare n bigint;
begin
  n := case p_prefixe
         when 'OUV' then nextval('gmb_prive.seq_ouverture')
         when 'CRE' then nextval('gmb_prive.seq_credit')
         when 'DEM' then nextval('gmb_prive.seq_demande')
         else nextval('gmb_prive.seq_reclam') end;
  return format('GMB-%s-%s-%s', p_prefixe, to_char(now(), 'YY'), lpad(n::text, 6, '0'));
end $$;

-- Clé de Luhn (identifiant bancaire à 8 chiffres, AUTH-01)
create or replace function gmb_prive.luhn_valide(p_numero text) returns boolean
language plpgsql immutable set search_path = '' as $$
declare s int := 0; d int; doubler boolean := false; i int;
begin
  if p_numero is null or p_numero !~ '^[0-9]+$' then return false; end if;
  for i in reverse length(p_numero)..1 loop
    d := substr(p_numero, i, 1)::int;
    if doubler then
      d := d * 2;
      if d > 9 then d := d - 9; end if;
    end if;
    s := s + d;
    doubler := not doubler;
  end loop;
  return s % 10 = 0;
end $$;

-- Nouvel identifiant bancaire unique (7 chiffres + clé de Luhn)
create or replace function gmb_prive.nouvel_identifiant() returns text
language plpgsql volatile security definer set search_path = '' as $$
declare base text; s int; d int; doubler boolean; i int; candidat text;
begin
  loop
    base := (1000000 + floor(random() * 9000000))::bigint::text;
    s := 0; doubler := true;
    for i in reverse 7..1 loop
      d := substr(base, i, 1)::int;
      if doubler then
        d := d * 2;
        if d > 9 then d := d - 9; end if;
      end if;
      s := s + d;
      doubler := not doubler;
    end loop;
    candidat := base || ((10 - s % 10) % 10)::text;
    exit when not exists (select 1 from public.clients where identifiant = candidat);
  end loop;
  return candidat;
end $$;

-- Contrôle d'un IBAN (modulo 97)
create or replace function gmb_prive.iban_valide(p_iban text) returns boolean
language plpgsql immutable set search_path = '' as $$
declare s text := upper(replace(coalesce(p_iban, ''), ' ', '')); r text := ''; c text; i int;
begin
  if s !~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$' then return false; end if;
  s := substr(s, 5) || substr(s, 1, 4);
  for i in 1..length(s) loop
    c := substr(s, i, 1);
    r := r || case when c ~ '[0-9]' then c else (ascii(c) - 55)::text end;
  end loop;
  return (r::numeric % 97) = 1;
end $$;

-- Numéro de compte GerMoonBank : 11 chiffres, dont une clé de Luhn finale.
-- Aucun IBAN n'est attribué tant qu'un établissement partenaire ne l'a pas fourni.
create or replace function gmb_prive.nouveau_numero_compte() returns text
language plpgsql volatile security definer set search_path = '' as $$
declare base text; s int; d int; doubler boolean; i int; candidat text;
begin
  loop
    base := lpad((floor(random() * 10000000000))::bigint::text, 10, '0');
    s := 0; doubler := true;
    for i in reverse 10..1 loop
      d := substr(base, i, 1)::int;
      if doubler then
        d := d * 2;
        if d > 9 then d := d - 9; end if;
      end if;
      s := s + d;
      doubler := not doubler;
    end loop;
    candidat := base || ((10 - s % 10) % 10)::text;
    exit when not exists (select 1 from public.comptes where numero = candidat);
  end loop;
  return candidat;
end $$;

-- Normalisation d'un nom pour la vérification du bénéficiaire (VoP)
create or replace function gmb_prive.normaliser_nom(p_nom text) returns text
language sql immutable set search_path = '' as $$
  select btrim(regexp_replace(regexp_replace(
           upper(translate(coalesce(p_nom, ''),
             'àâäáãåçéèêëíìîïñóòôöõúùûüýÿÀÂÄÁÃÅÇÉÈÊËÍÌÎÏÑÓÒÔÖÕÚÙÛÜÝŸ',
             'aaaaaaceeeeiiiinooooouuuuyyAAAAAACEEEEIIIINOOOOOUUUUYY')),
           '[^A-Z -]', ' ', 'g'), '\s+', ' ', 'g'))
$$;

-- Dimanche de Pâques (algorithme grégorien anonyme)
create or replace function gmb_prive.paques(p_annee int) returns date
language plpgsql immutable set search_path = '' as $$
declare a int := p_annee % 19; b int := p_annee / 100; c int := p_annee % 100; d int; e int; f int; g int; h int; i int; k int; l int; m int; mois int; jour int;
begin
  d := b / 4; e := b % 4; f := (b + 8) / 25; g := (b - f + 1) / 3;
  h := (19 * a + b - d - g + 15) % 30; i := c / 4; k := c % 4;
  l := (32 + 2 * e + 2 * i - h - k) % 7; m := (a + 11 * h + 22 * l) / 451;
  mois := (h + l - 7 * m + 114) / 31; jour := ((h + l - 7 * m + 114) % 31) + 1;
  return make_date(p_annee, mois, jour);
end $$;

-- Jour férié en France métropolitaine (11 jours, dont 3 liés à Pâques)
create or replace function gmb_prive.jour_ferie(p_jour date) returns boolean
language plpgsql immutable set search_path = '' as $$
declare an int := extract(year from p_jour)::int; p date := gmb_prive.paques(extract(year from p_jour)::int);
begin
  return p_jour in (make_date(an, 1, 1), p + 1, make_date(an, 5, 1), make_date(an, 5, 8), p + 39, p + 50,
                    make_date(an, 7, 14), make_date(an, 8, 15), make_date(an, 11, 1), make_date(an, 11, 11), make_date(an, 12, 25));
end $$;

-- Ajout de jours ouvrés : samedis, dimanches et jours fériés exclus
create or replace function gmb_prive.ajouter_jours_ouvres(p_depart timestamptz, p_jours int) returns timestamptz
language plpgsql stable set search_path = '' as $$
declare d timestamptz := p_depart; n int := 0;
begin
  while n < p_jours loop
    d := d + interval '1 day';
    if extract(isodow from d) < 6 and not gmb_prive.jour_ferie((d at time zone 'Europe/Paris')::date) then
      n := n + 1;
    end if;
  end loop;
  return d;
end $$;

-- Mensualité d'un prêt amortissable à taux fixe (VIT-15)
-- Contrôle : 10 000 € sur 48 mois à 5,75 % → 233,71 €
create or replace function gmb_prive.mensualite(p_capital numeric, p_taux numeric, p_mois int) returns numeric
language sql immutable set search_path = '' as $$
  select case when p_taux = 0 then round(p_capital / p_mois, 2)
              else round(p_capital * (p_taux / 1200) / (1 - power(1 + p_taux / 1200, -p_mois)), 2) end
$$;

-- TAEG sans frais annexes (prêt sans frais de dossier) : 5,75 % → 5,90 %
create or replace function gmb_prive.taeg(p_taux numeric) returns numeric
language sql immutable set search_path = '' as $$
  select round((power(1 + p_taux / 1200, 12) - 1) * 100, 2)
$$;


-- =============================================================================
-- 2. RÉFÉRENTIEL ET CATALOGUE (VIT-17, VIT-23, ADM-03)
-- Source unique des prix, taux et franchises : la vitrine, les simulateurs,
-- l'Espace client et les documents tarifaires lisent ces tables.
-- =============================================================================
create table public.formules (
  code                    text primary key check (code ~ '^[a-z_]+$'),
  segment                 text not null check (segment in ('particulier', 'pro', 'business')),
  nom                     text not null,
  accroche                text,
  prix_mensuel            numeric(8,2) not null check (prix_mensuel >= 0),
  prix_ht                 boolean not null default false,
  carte                   text,
  retraits_hors_zone_mois numeric(10,2),
  change_sans_frais_mois  numeric(10,2),              -- vide = illimité (jours ouvrés)
  taux_livret             numeric(5,3),               -- taux annuel brut en %
  moonpoints_taux         numeric(5,3) not null default 0,
  coffres_max             int,                        -- vide = illimité
  cartes_physiques        int not null default 1,
  cartes_virtuelles       int not null default 1,
  utilisateurs_max        int,
  operations_incluses     int,
  assurances              text[] not null default '{}',
  services                text[] not null default '{}',
  badge                   text,
  ordre                   int not null default 0,
  actif                   boolean not null default true,
  date_effet              date not null default current_date,
  updated_at              timestamptz not null default now()
);
comment on table public.formules is 'GMB : formules Particuliers, Pro et Business (VIT-17, VIT-23, ADM-03).';

create table public.formules_historique (
  id           bigint generated always as identity primary key,
  formule_code text not null references public.formules(code) on delete cascade,
  avant        jsonb,
  apres        jsonb not null,
  modifie_par  uuid,
  modifie_le   timestamptz not null default now()
);
comment on table public.formules_historique is 'GMB : historique des prix et taux, preuve de l''information délivrée (ADM-03).';

create table public.frais (
  code        text primary key,
  libelle     text not null,
  pourcentage numeric(6,3),
  montant     numeric(10,2),
  minimum     numeric(10,2),
  conditions  text,
  actif       boolean not null default true,
  updated_at  timestamptz not null default now()
);
comment on table public.frais is 'GMB : frais hors formule, affichés avant chaque opération (VIT-14, VIT-17).';

create table public.taux_usure (
  id          bigint generated always as identity primary key,
  categorie   text not null,
  taux        numeric(6,3) not null check (taux > 0),
  valable_du  date not null,
  valable_au  date not null,
  source      text,
  unique (categorie, valable_du),
  check (valable_du <= valable_au)
);
comment on table public.taux_usure is 'GMB : taux d''usure publiés chaque trimestre ; contrôle bloquant des grilles de crédit.';

create table public.grilles_credit (
  id                uuid primary key default gen_random_uuid(),
  produit           text not null default 'pret_personnel' check (produit in ('pret_personnel', 'pret_immobilier')),
  objet             text not null default 'tous' check (objet in ('tous', 'auto_moto', 'travaux', 'etudes', 'autre')),
  montant_min       numeric(12,2) not null,
  montant_max       numeric(12,2) not null,
  duree_min         int not null,
  duree_max         int not null,
  taux_debiteur     numeric(6,3) not null check (taux_debiteur >= 0),
  categorie_usure   text not null default 'conso_plus_6000',
  actif             boolean not null default true,
  valide_conformite boolean not null default false,
  date_effet        date not null default current_date,
  updated_at        timestamptz not null default now(),
  check (montant_min <= montant_max and duree_min <= duree_max)
);
comment on table public.grilles_credit is 'GMB : grilles de taux du prêt personnel (VIT-15, PAR-12, ADM-03).';

create table public.categories (
  code    text primary key,
  libelle text not null,
  icone   text not null,
  couleur text not null default 'violet',
  ordre   int not null default 0
);
comment on table public.categories is 'GMB : catégories de dépenses et de revenus (PAR-03, PAR-07).';


-- =============================================================================
-- 3. CMS DE LA VITRINE ET ÉTAT DES SERVICES (ADM-02, VIT-44, VIT-45, ADM-12)
-- =============================================================================
create table public.cms_pages (
  id              uuid primary key default gen_random_uuid(),
  ecran           text,                               -- identifiant du cahier des charges, ex. VIT-11
  slug            text not null,                      -- '' = accueil ; ex. 'particuliers/epargne'
  langue          text not null default 'fr' check (langue in ('fr', 'en')),
  titre           text not null,
  titre_seo       text check (char_length(titre_seo) <= 60),
  description_seo text check (char_length(description_seo) <= 155),
  blocs           jsonb not null default '[]'::jsonb,
  blocs_brouillon jsonb,                              -- version en cours de rédaction ; « blocs » reste en ligne
  en_ligne        boolean not null default false,
  statut          text not null default 'brouillon'
                  check (statut in ('brouillon', 'relecture_conformite', 'validation_juridique', 'planifiee', 'publiee', 'archivee')),
  version         int not null default 1,
  planifiee_le    timestamptz,
  publiee_le      timestamptz,
  auteur_id       uuid,
  relecteur_id    uuid,
  approbateur_id  uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (slug, langue)
);
comment on table public.cms_pages is 'GMB : pages de la vitrine composées de blocs, avec circuit de publication (ADM-02).';

create table public.cms_versions (
  id         bigint generated always as identity primary key,
  page_id    uuid not null references public.cms_pages(id) on delete cascade,
  version    int not null,
  blocs      jsonb not null,
  statut     text not null,
  auteur_id  uuid,
  created_at timestamptz not null default now(),
  unique (page_id, version)
);
comment on table public.cms_versions is 'GMB : versions successives des pages, republiables (ADM-02).';

create table public.cms_textes_legaux (
  code         text primary key,                      -- ex. LEG-FGDR-02
  titre        text not null,
  contenu      text not null,
  entite       text,
  version      int not null default 1,
  date_effet   date not null default current_date,
  proprietaire text not null default 'juridique',
  updated_at   timestamptz not null default now()
);
comment on table public.cms_textes_legaux is 'GMB : bibliothèque juridique, textes verrouillés modifiables par le service juridique seul.';

create table public.cms_bandeaux (
  id             uuid primary key default gen_random_uuid(),
  niveau         text not null check (niveau in ('promotion', 'information', 'alerte_fraude', 'incident')),
  message        text not null,
  lien_libelle   text,
  lien_url       text,
  conditions_url text,
  espaces        text[] not null default '{vitrine}',
  debut          timestamptz,
  fin            timestamptz,
  fermable       boolean generated always as (niveau <> 'incident') stored,
  actif          boolean not null default true,
  created_at     timestamptz not null default now(),
  check (niveau <> 'promotion' or conditions_url is not null)  -- une promotion de taux renvoie à ses conditions
);
comment on table public.cms_bandeaux is 'GMB : bandeaux promotion, information, alerte fraude et incident (VIT-00).';

create table public.cms_faq (
  id         uuid primary key default gen_random_uuid(),
  rubrique   text not null,
  question   text not null,
  reponse    text not null,
  ordre      int not null default 0,
  publie     boolean not null default true,
  utile      int not null default 0,
  inutile    int not null default 0,
  updated_at timestamptz not null default now()
);
comment on table public.cms_faq is 'GMB : questions fréquentes du centre d''aide et des pages produit (VIT-42).';

create table public.cms_redirections (
  source     text primary key,
  cible      text not null,
  code       int not null default 301 check (code in (301, 302)),
  created_at timestamptz not null default now()
);
comment on table public.cms_redirections is 'GMB : redirections créées à chaque changement d''adresse (SEO).';

create table public.cms_medias (
  id               uuid primary key default gen_random_uuid(),
  chemin           text not null unique,
  texte_alternatif text not null check (char_length(texte_alternatif) between 3 and 250),
  credits          text,
  created_at       timestamptz not null default now()
);
comment on table public.cms_medias is 'GMB : médias de la vitrine, texte alternatif obligatoire (accessibilité).';

create table public.statut_services (
  service text primary key,
  libelle text not null,
  etat    text not null default 'operationnel' check (etat in ('operationnel', 'degrade', 'panne', 'maintenance')),
  message text,
  maj_le  timestamptz not null default now()
);
comment on table public.statut_services is 'GMB : état des services affiché sur status.germoonbank.eu (VIT-45).';

create table public.incidents (
  id                          uuid primary key default gen_random_uuid(),
  titre                       text not null,
  description                 text,
  classification              text not null default 'mineur' check (classification in ('mineur', 'significatif', 'majeur')),
  services                    text[] not null default '{}',
  detecte_le                  timestamptz not null default now(),
  classe_le                   timestamptz,
  notif_initiale_avant        timestamptz,
  rapport_intermediaire_avant timestamptz,
  rapport_final_avant         timestamptz,
  statut                      text not null default 'ouvert' check (statut in ('ouvert', 'en_cours', 'resolu', 'clos')),
  public                      boolean not null default false,
  resolu_le                   timestamptz,
  created_at                  timestamptz not null default now()
);
comment on table public.incidents is 'GMB : incidents informatiques et délais de notification DORA (ADM-12).';


-- =============================================================================
-- 4. PROSPECTS ET DOSSIERS — ESPACE MON DOSSIER (ONB, DOS, ADM-04, ADM-08)
-- Règle « deux portes, deux clés » : un dossier appartient à un compte
-- Mon Dossier (e-mail et mot de passe) et ne donne jamais accès aux comptes.
-- =============================================================================
create table public.personnes (
  id                 uuid primary key default gen_random_uuid(),
  civilite           text check (civilite in ('madame', 'monsieur', 'non_precise')),
  nom_naissance      text,
  nom_usage          text,
  prenoms            text,
  date_naissance     date,
  lieu_naissance     text,
  pays_naissance     text default 'FR',
  nationalite        text default 'FR',
  email              extensions.citext,
  telephone          text check (telephone is null or telephone ~ '^\+[0-9]{8,15}$'),
  adresse_ligne1     text,
  adresse_ligne2     text,
  code_postal        text,
  ville              text,
  pays               text default 'FR',
  profession         text,
  revenus_tranche    text,
  patrimoine_tranche text,
  origine_fonds      text,
  residence_fiscale  text default 'FR',
  nif                text,
  personne_us        boolean,
  ppe_declaree       boolean,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
comment on table public.personnes is 'GMB : identité et situation des demandeurs et des clients (ONB-04, ONB-05).';
create index personnes_email_idx on public.personnes (email);

-- Profil de risque LCB-FT : jamais visible par le client (interdiction d'informer)
create table public.profils_risque (
  personne_id uuid primary key references public.personnes(id) on delete cascade,
  niveau      text not null default 'faible' check (niveau in ('faible', 'moyen', 'eleve')),
  score       int not null default 0 check (score between 0 and 100),
  motifs      text[] not null default '{}',
  revue_avant date,
  maj_le      timestamptz not null default now()
);
comment on table public.profils_risque is 'GMB : niveau de risque LCB-FT, réservé au back-office (ADM-04, ADM-05).';

create table public.consentements (
  id           uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  personne_id  uuid references public.personnes(id) on delete cascade,
  type         text not null check (type in ('cgu', 'confidentialite', 'biometrie', 'marketing', 'cookies', 'ficp', 'signature_convention')),
  version      text not null,
  accorde      boolean not null,
  horodatage   timestamptz not null default now(),
  source       text
);
comment on table public.consentements is 'GMB : consentements horodatés (RGPD, biométrie, FICP, signature) — preuve conservée.';
create index consentements_user_idx on public.consentements (auth_user_id, type);

create table public.dossiers (
  id                 uuid primary key default gen_random_uuid(),
  reference          text not null unique,
  type               text not null check (type in ('ouverture', 'credit')),
  segment            text not null default 'particulier' check (segment in ('particulier', 'pro', 'business', 'jeunes')),
  formule_code       text references public.formules(code),
  etat               text not null default 'brouillon',
  demandeur_auth     uuid references auth.users(id) on delete set null,  -- compte Mon Dossier
  personne_id        uuid references public.personnes(id) on delete set null,
  analyste_id        uuid,
  etape_tunnel       int not null default 1 check (etape_tunnel between 1 and 11),
  depose_le          timestamptz,
  sla_echeance       timestamptz,
  complement_avant   date,
  decision_le        timestamptz,
  ouvert_le          timestamptz,
  identifiant_vu_le  timestamptz,
  derniere_activite  timestamptz not null default now(),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint dossiers_etat_selon_type check (
    (type = 'ouverture' and etat in ('brouillon', 'depose', 'en_verification', 'incomplet', 'analyse_conformite',
                                     'valide', 'compte_ouvert', 'refuse', 'abandonne', 'archive'))
    or
    (type = 'credit' and etat in ('brouillon', 'demande_deposee', 'analyse', 'incomplet', 'offre_emise', 'delai_legal',
                                  'acceptee', 'fonds_debloques', 'refusee', 'renonciation', 'abandonne', 'archive')))
);
comment on table public.dossiers is 'GMB : dossiers d''ouverture de compte et de crédit suivis dans l''Espace Mon Dossier (DOS-03).';
create index dossiers_demandeur_idx on public.dossiers (demandeur_auth);
create index dossiers_etat_idx on public.dossiers (etat, sla_echeance);

create table public.dossier_credit (
  dossier_id            uuid primary key references public.dossiers(id) on delete cascade,
  produit               text not null default 'pret_personnel',
  objet                 text not null default 'autre',
  montant               numeric(12,2) not null check (montant between 1000 and 50000),
  duree_mois            int not null check (duree_mois between 6 and 84),
  revenus_mensuels      numeric(12,2),
  charges_mensuelles    numeric(12,2),
  taux_debiteur         numeric(6,3),
  taeg                  numeric(6,3),
  mensualite            numeric(12,2),
  cout_total            numeric(12,2),
  montant_total_du      numeric(12,2),
  consentement_ficp     boolean not null default false,
  ficp_consulte_le      timestamptz,
  offre_emise_le        timestamptz,
  acceptee_le           timestamptz,
  retractation_fin      timestamptz,
  deblocage_possible_le timestamptz,
  fonds_debloques_le    timestamptz,
  -- Code de la consommation : aucun versement avant le 8e jour suivant l'acceptation
  check (fonds_debloques_le is null or (acceptee_le is not null and fonds_debloques_le::date >= acceptee_le::date + 7))
);
comment on table public.dossier_credit is 'GMB : détail d''une demande de crédit d''un non-client (ONB-C, DOS-06).';

create table public.dossier_evenements (
  id             bigint generated always as identity primary key,
  dossier_id     uuid not null references public.dossiers(id) on delete cascade,
  etat_avant     text,
  etat_apres     text not null,
  acteur         text not null check (acteur in ('client', 'analyste', 'systeme')),
  libelle_client text not null,
  created_at     timestamptz not null default now()
);
comment on table public.dossier_evenements is 'GMB : frise d''avancement visible par le demandeur, en langage clair (DOS-03).';
create index dossier_evenements_idx on public.dossier_evenements (dossier_id, created_at);

-- Notes et motifs internes : jamais visibles par le demandeur
create table public.dossier_notes_internes (
  id         bigint generated always as identity primary key,
  dossier_id uuid not null references public.dossiers(id) on delete cascade,
  auteur_id  uuid,
  decision   text,
  motif_code text,
  note       text not null,
  created_at timestamptz not null default now()
);
comment on table public.dossier_notes_internes is 'GMB : notes et motifs internes des analystes (ADM-04), invisibles pour le client.';

create table public.dossier_pieces (
  id                 uuid primary key default gen_random_uuid(),
  dossier_id         uuid not null references public.dossiers(id) on delete cascade,
  type               text not null check (type in ('piece_identite', 'selfie', 'justificatif_domicile', 'justificatif_revenus',
                                                   'kbis', 'statuts', 'beneficiaires_effectifs', 'lien_filiation', 'autre')),
  statut             text not null default 'attendue' check (statut in ('attendue', 'deposee', 'en_controle', 'validee', 'refusee', 'facultative')),
  motif_refus_client text,
  fichier_chemin     text,                          -- stockage « gmb-pieces » : {auth.uid}/{dossier}/{fichier}
  empreinte_sha256   text,
  date_document      date,
  depose_le          timestamptz,
  controle_le        timestamptz,
  created_at         timestamptz not null default now()
);
comment on table public.dossier_pieces is 'GMB : pièces du dossier et leur état (ONB-07, ONB-08, DOS-04).';
create index dossier_pieces_idx on public.dossier_pieces (dossier_id);

create table public.dossier_controles (
  id         uuid primary key default gen_random_uuid(),
  dossier_id uuid not null references public.dossiers(id) on delete cascade,
  controle   text not null check (controle in ('authenticite', 'vivacite', 'concordance_visage', 'gel_avoirs', 'ppe',
                                               'domicile', 'premier_versement', 'doublon', 'appareil', 'ficp', 'solvabilite')),
  resultat   text not null check (resultat in ('conforme', 'non_conforme', 'a_revoir')),
  score      numeric(5,2),
  details    jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
comment on table public.dossier_controles is 'GMB : contrôles automatiques KYC et crédit, réservés au back-office (ADM-04).';
create index dossier_controles_idx on public.dossier_controles (dossier_id, controle, created_at desc);

-- Principe des quatre yeux : validations successives par des analystes distincts
create table public.dossier_validations (
  dossier_id  uuid not null references public.dossiers(id) on delete cascade,
  analyste_id uuid not null,
  created_at  timestamptz not null default now(),
  primary key (dossier_id, analyste_id)
);
comment on table public.dossier_validations is 'GMB : validations successives d''un dossier à risque (quatre yeux).';

create table public.dossier_messages (
  id            uuid primary key default gen_random_uuid(),
  dossier_id    uuid not null references public.dossiers(id) on delete cascade,
  auteur        text not null check (auteur in ('client', 'conseiller', 'systeme')),
  auteur_id     uuid,
  contenu       text not null check (char_length(contenu) between 1 and 4000),
  pieces_jointes jsonb not null default '[]'::jsonb,
  lu_le         timestamptz,
  created_at    timestamptz not null default now()
);
comment on table public.dossier_messages is 'GMB : messagerie liée au dossier (DOS-05).';
create index dossier_messages_idx on public.dossier_messages (dossier_id, created_at);

create table public.dossier_rendez_vous (
  id         uuid primary key default gen_random_uuid(),
  dossier_id uuid not null references public.dossiers(id) on delete cascade,
  debut      timestamptz not null,
  duree_min  int not null default 15,
  canal      text not null default 'video' check (canal in ('video', 'telephone')),
  statut     text not null default 'demande' check (statut in ('demande', 'confirme', 'annule', 'termine')),
  created_at timestamptz not null default now()
);
comment on table public.dossier_rendez_vous is 'GMB : rendez-vous vidéo de 15 minutes avec un conseiller (DOS-05).';

create table public.premiers_versements (
  id            uuid primary key default gen_random_uuid(),
  dossier_id    uuid not null unique references public.dossiers(id) on delete cascade,
  montant       numeric(10,2) not null check (montant between 10 and 1000),
  moyen         text not null default 'virement' check (moyen = 'virement'),
  nom_titulaire text not null,
  statut        text not null default 'attendu' check (statut in ('attendu', 'recu', 'en_revue', 'credite', 'rembourse')),
  montant_recu  numeric(10,2),
  declare_le    timestamptz not null default now(),
  recu_le       timestamptz,
  credite_le    timestamptz,
  rembourse_le  timestamptz
);
comment on table public.premiers_versements is 'GMB : premier versement depuis un compte au nom du demandeur dans l''EEE (ONB-10).';


-- =============================================================================
-- 5. CLIENTS, COMPTES ET PAIEMENTS — ESPACE CLIENT (AUTH, PAR, ADM-07)
-- =============================================================================
create table public.entreprises (
  id             uuid primary key default gen_random_uuid(),
  raison_sociale text not null,
  siren          text unique check (siren ~ '^[0-9]{9}$'),
  forme          text,
  formule_code   text references public.formules(code),
  adresse        text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
comment on table public.entreprises is 'GMB : entreprises clientes Business et Pro en société (BIZ, ADM-11).';

create table public.clients (
  id                    uuid primary key default gen_random_uuid(),
  personne_id           uuid not null references public.personnes(id),
  identifiant           char(8) not null unique check (gmb_prive.luhn_valide(identifiant)),
  segment               text not null default 'particulier' check (segment in ('particulier', 'pro', 'business', 'jeunes')),
  formule_code          text references public.formules(code),
  statut                text not null default 'actif' check (statut in ('actif', 'inactif', 'bloque', 'cloture')),
  auth_user_id          uuid unique references auth.users(id) on delete set null,  -- compte Espace client
  dossier_origine_id    uuid references public.dossiers(id) on delete set null,
  theme                 text not null default 'clair' check (theme in ('clair', 'sombre', 'systeme')),
  langue                text not null default 'fr' check (langue in ('fr', 'en')),
  preferences           jsonb not null default '{"push": true, "email": true, "sms": false, "discretion": false}'::jsonb,
  ficoba_declare_le     timestamptz,
  ouvert_le             timestamptz not null default now(),
  cloture_le            timestamptz,
  derniere_operation_le timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
comment on table public.clients is 'GMB : clients ; identifiant bancaire à 8 chiffres avec clé de Luhn (AUTH-01).';

create table public.comptes (
  id               uuid primary key default gen_random_uuid(),
  client_id        uuid references public.clients(id) on delete cascade,
  entreprise_id    uuid references public.entreprises(id) on delete cascade,
  type             text not null check (type in ('courant', 'livret', 'coffre', 'devise', 'crypto', 'titres', 'jeune', 'pro', 'business')),
  libelle          text not null,
  numero             text unique check (numero is null or gmb_prive.luhn_valide(numero)),
  iban             text unique check (iban is null or gmb_prive.iban_valide(iban)),
  bic              text,
  devise           char(3) not null default 'EUR',
  solde            numeric(14,2) not null default 0,
  taux             numeric(5,3),
  plafond          numeric(14,2),
  compte_parent_id uuid references public.comptes(id) on delete cascade,
  statut           text not null default 'actif' check (statut in ('actif', 'bloque', 'cloture')),
  ouvert_le        timestamptz not null default now(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (client_id is not null or entreprise_id is not null)
);
comment on table public.comptes is 'GMB : comptes courant, Livret GMB, coffres, devises, crypto, Jeunes, Pro et Business (PAR-02).';
create index comptes_client_idx on public.comptes (client_id);
create index comptes_entreprise_idx on public.comptes (entreprise_id);

create table public.coffres (
  id                     uuid primary key default gen_random_uuid(),
  client_id              uuid not null references public.clients(id) on delete cascade,
  compte_id              uuid not null unique references public.comptes(id) on delete cascade,
  nom                    text not null check (char_length(nom) between 1 and 40),
  objectif               numeric(12,2) check (objectif is null or objectif > 0),
  date_objectif          date,
  image                  text,
  arrondi_multiplicateur int not null default 0 check (arrondi_multiplicateur between 0 and 3),
  statut                 text not null default 'actif' check (statut in ('actif', 'atteint', 'clos')),
  demarre_le             date,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
comment on table public.coffres is 'GMB : coffres d''épargne par projet, objectifs et arrondis (PAR-06, JEU-02).';

create table public.cartes (
  id                    uuid primary key default gen_random_uuid(),
  compte_id             uuid not null references public.comptes(id) on delete cascade,
  titulaire_client_id   uuid not null references public.clients(id) on delete cascade,
  type                  text not null check (type in ('physique', 'virtuelle', 'ephemere')),
  gamme                 text not null,
  derniers_chiffres     char(4) not null check (derniers_chiffres ~ '^[0-9]{4}$'),
  expiration            char(5) not null check (expiration ~ '^(0[1-9]|1[0-2])/[0-9]{2}$'),
  jeton_processeur      text,       -- référence chez le processeur : AUCUN numéro complet ni cryptogramme ici
  statut                text not null default 'active' check (statut in ('commandee', 'active', 'gelee', 'opposition', 'expiree')),
  sans_contact          boolean not null default true,
  paiement_en_ligne     boolean not null default true,
  retraits              boolean not null default true,
  etranger              boolean not null default true,
  plafond_paiement_30j  numeric(12,2) not null default 2500,
  plafond_retrait_7j    numeric(12,2) not null default 1000,
  motif_opposition      text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
comment on table public.cartes is 'GMB : cartes physiques, virtuelles et éphémères ; aucune donnée PCI stockée (PAR-04).';
create index cartes_compte_idx on public.cartes (compte_id);

create table public.beneficiaires (
  id                      uuid primary key default gen_random_uuid(),
  client_id               uuid references public.clients(id) on delete cascade,
  entreprise_id           uuid references public.entreprises(id) on delete cascade,
  nom                     text not null,
  nom_verifie             text,
  iban                    text check (iban is null or gmb_prive.iban_valide(iban)),
  numero_compte text check (numero_compte is null or numero_compte ~ '^[0-9]{11}$'),
  vop_resultat            text not null check (vop_resultat in ('correspondance', 'partielle', 'aucune', 'impossible')),
  vop_le                  timestamptz not null default now(),
  plafond_temporaire      numeric(12,2) not null default 1000,
  plafond_temporaire_jusqu timestamptz not null default now() + interval '72 hours',
  favori                  boolean not null default false,
  created_at              timestamptz not null default now(),
  check (client_id is not null or entreprise_id is not null)
);
comment on table public.beneficiaires is 'GMB : bénéficiaires, résultat de la vérification du nom et plafond de 72 heures (PAR-05).';

create table public.virements (
  id              uuid primary key default gen_random_uuid(),
  compte_id       uuid not null references public.comptes(id) on delete cascade,
  beneficiaire_id uuid references public.beneficiaires(id) on delete set null,
  montant         numeric(14,2) not null check (montant > 0),
  devise          char(3) not null default 'EUR',
  motif           text check (char_length(motif) <= 140),
  type            text not null default 'instantane' check (type in ('instantane', 'standard', 'differe', 'permanent')),
  date_execution  date not null default current_date,
  frequence       text check (frequence in ('hebdomadaire', 'mensuelle', 'trimestrielle', 'annuelle')),
  statut          text not null default 'a_valider'
                  check (statut in ('a_valider', 'en_approbation', 'valide', 'a_executer', 'execute', 'rejete', 'annule')),
  vop_resultat    text,
  vop_choix       text check (vop_choix in ('nom_corrige', 'continuer', 'annuler')),
  sca_le          timestamptz,
  execute_le      timestamptz,
  motif_rejet     text,
  reference_execution text,
  cree_par        uuid,
  created_at      timestamptz not null default now()
);
comment on table public.virements is 'GMB : virements instantanés, standards, différés et permanents (PAR-05, BIZ-04).';
create index virements_compte_idx on public.virements (compte_id, created_at desc);

create table public.budgets (
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null references public.clients(id) on delete cascade,
  mois          date not null check (extract(day from mois) = 1),
  montant       numeric(12,2) not null check (montant > 0),
  par_categorie jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now(),
  unique (client_id, mois)
);
comment on table public.budgets is 'GMB : budget mensuel affiché en lune décroissante (PAR-07).';

create table public.operations (
  id                  uuid primary key default gen_random_uuid(),
  compte_id           uuid not null references public.comptes(id) on delete cascade,
  type                text not null check (type in ('carte', 'virement_emis', 'virement_recu', 'prelevement', 'interets', 'frais',
                                                    'arrondi', 'interne', 'remboursement', 'versement_initial', 'moonpoints',
                                                    'argent_de_poche', 'credit')),
  libelle             text not null,
  contrepartie_nom    text,
  contrepartie_iban   text,
  montant             numeric(14,2) not null check (montant <> 0),
  devise              char(3) not null default 'EUR',
  montant_origine     numeric(14,2),
  devise_origine      char(3),
  taux_change         numeric(12,6),
  ecart_bce_pct       numeric(6,3),
  statut              text not null default 'comptabilisee' check (statut in ('en_attente', 'comptabilisee', 'refusee', 'annulee')),
  motif_refus         text,
  categorie_code      text references public.categories(code),
  carte_id            uuid references public.cartes(id) on delete set null,
  virement_id         uuid references public.virements(id) on delete set null,
  budget_id           uuid references public.budgets(id) on delete set null,
  mcc                 text,
  lieu                text,
  pointee             boolean not null default false,
  motif               text check (char_length(motif) <= 140),
  justificatif_chemin text,
  reference           text,
  date_operation      timestamptz not null default now(),
  date_valeur         date not null default current_date,
  created_at          timestamptz not null default now()
);
comment on table public.operations is 'GMB : opérations de compte, pointage, motif et justificatif (PAR-02, PAR-03).';
create index operations_compte_idx on public.operations (compte_id, date_operation desc);

create table public.mandats_prelevement (
  id            uuid primary key default gen_random_uuid(),
  compte_id     uuid not null references public.comptes(id) on delete cascade,
  creancier_nom text not null,
  ics           text not null,
  rum           text not null,
  liste         text not null default 'autorise' check (liste in ('autorise', 'bloque')),
  statut        text not null default 'actif' check (statut in ('actif', 'revoque', 'suspendu')),
  plafond       numeric(12,2),
  created_at    timestamptz not null default now(),
  revoque_le    timestamptz,
  unique (compte_id, rum)
);
comment on table public.mandats_prelevement is 'GMB : mandats SEPA, révocation, créanciers autorisés ou bloqués (PAR-11).';

create table public.moonpoints (
  id           bigint generated always as identity primary key,
  client_id    uuid not null references public.clients(id) on delete cascade,
  points       int not null check (points <> 0),
  motif        text not null,
  operation_id uuid references public.operations(id) on delete set null,
  expire_le    date,
  created_at   timestamptz not null default now()
);
comment on table public.moonpoints is 'GMB : programme de fidélité MoonPoints, 100 points = 1 € (PAR-07).';
create index moonpoints_client_idx on public.moonpoints (client_id);

create table public.interets (
  compte_id   uuid not null references public.comptes(id) on delete cascade,
  jour        date not null,
  solde_base  numeric(14,2) not null,
  taux        numeric(5,3) not null,
  montant     numeric(12,2) not null,
  primary key (compte_id, jour)
);
comment on table public.interets is 'GMB : intérêts du Livret GMB calculés et versés chaque jour (PAR-06).';

create table public.documents (
  id         uuid primary key default gen_random_uuid(),
  client_id  uuid not null references public.clients(id) on delete cascade,
  type       text not null check (type in ('releve', 'rib', 'attestation', 'contrat', 'releve_frais', 'ifu', 'fiche_fgdr', 'offre_credit', 'autre')),
  titre      text not null,
  periode    text,
  chemin     text not null,          -- stockage « gmb-documents » : {client_id}/{fichier}
  created_at timestamptz not null default now()
);
comment on table public.documents is 'GMB : relevés, RIB, attestations, contrats et documents fiscaux (PAR-14).';

create table public.demandes (
  id                    uuid primary key default gen_random_uuid(),
  client_id             uuid not null references public.clients(id) on delete cascade,
  reference             text not null unique,
  type                  text not null check (type in ('pret_personnel', 'carte_supplementaire', 'plafond_exceptionnel',
                                                      'compte_jeune', 'espace_pro', 'changement_formule')),
  etat                  text not null default 'demande_deposee'
                        check (etat in ('demande_deposee', 'analyse', 'incomplet', 'offre_emise', 'delai_legal', 'acceptee',
                                        'fonds_debloques', 'refusee', 'renonciation', 'validee', 'realisee', 'annulee')),
  montant               numeric(12,2),
  duree_mois            int,
  objet                 text,
  taux_debiteur         numeric(6,3),
  taeg                  numeric(6,3),
  mensualite            numeric(12,2),
  cout_total            numeric(12,2),
  montant_total_du      numeric(12,2),
  offre_emise_le        timestamptz,
  acceptee_le           timestamptz,
  retractation_fin      timestamptz,
  deblocage_possible_le timestamptz,
  fonds_debloques_le    timestamptz,
  donnees               jsonb not null default '{}'::jsonb,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  check (fonds_debloques_le is null or (acceptee_le is not null and fonds_debloques_le::date >= acceptee_le::date + 7))
);
comment on table public.demandes is 'GMB : nouvelles demandes d''un client, suivies dans « Mes demandes » (PAR-13).';

create table public.demande_evenements (
  id             bigint generated always as identity primary key,
  demande_id     uuid not null references public.demandes(id) on delete cascade,
  etat_avant     text,
  etat_apres     text not null,
  libelle_client text not null,
  created_at     timestamptz not null default now()
);
comment on table public.demande_evenements is 'GMB : frise d''avancement des demandes d''un client (PAR-13).';

create table public.credits (
  id              uuid primary key default gen_random_uuid(),
  client_id       uuid not null references public.clients(id) on delete cascade,
  demande_id      uuid unique references public.demandes(id) on delete set null,
  compte_id       uuid references public.comptes(id),
  montant         numeric(12,2) not null,
  duree_mois      int not null,
  taux_debiteur   numeric(6,3) not null,
  taeg            numeric(6,3) not null,
  mensualite      numeric(12,2) not null,
  debut           date not null,
  capital_restant numeric(12,2) not null,
  statut          text not null default 'en_cours' check (statut in ('en_cours', 'rembourse', 'impaye')),
  created_at      timestamptz not null default now()
);
comment on table public.credits is 'GMB : prêts en cours, capital restant dû (PAR-12).';

-- GerMoonBank · installation de la base, partie 2 sur 8
-- Exécutez les parties dans l'ordre, chacune dans une requête vide du SQL Editor.
-- Contenu : 02_tables, 03_fonctions
create table public.credit_echeances (
  credit_id        uuid not null references public.credits(id) on delete cascade,
  numero           int not null,
  date_echeance    date not null,
  capital          numeric(12,2) not null,
  interets         numeric(12,2) not null,
  montant          numeric(12,2) not null,
  capital_restant  numeric(12,2) not null,
  statut           text not null default 'a_venir' check (statut in ('a_venir', 'payee', 'impayee')),
  primary key (credit_id, numero)
);
comment on table public.credit_echeances is 'GMB : tableau d''amortissement (PAR-12).';

create table public.fils_messagerie (
  id         uuid primary key default gen_random_uuid(),
  client_id  uuid not null references public.clients(id) on delete cascade,
  sujet      text not null,
  statut     text not null default 'ouvert' check (statut in ('ouvert', 'en_attente_client', 'clos')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table public.fils_messagerie is 'GMB : conversations avec un conseiller ou l''assistant (PAR-15, ADM-09).';

create table public.messages (
  id         uuid primary key default gen_random_uuid(),
  fil_id     uuid not null references public.fils_messagerie(id) on delete cascade,
  auteur     text not null check (auteur in ('client', 'conseiller', 'assistant', 'systeme')),
  auteur_id  uuid,
  contenu    text not null check (char_length(contenu) between 1 and 4000),
  lu_le      timestamptz,
  created_at timestamptz not null default now()
);
comment on table public.messages is 'GMB : messages ; ceux de l''assistant sont signalés comme automatisés (règlement IA).';
create index messages_fil_idx on public.messages (fil_id, created_at);

create table public.reclamations (
  id               uuid primary key default gen_random_uuid(),
  client_id        uuid not null references public.clients(id) on delete cascade,
  reference        text not null unique,
  categorie        text not null default 'autre' check (categorie in ('paiement', 'carte', 'credit', 'compte', 'autre')),
  objet            text not null,
  description      text not null,
  statut           text not null default 'recue' check (statut in ('recue', 'en_cours', 'repondue', 'close')),
  accuse_avant     timestamptz not null,
  reponse_avant    timestamptz not null,
  accuse_le        timestamptz,
  repondue_le      timestamptz,
  reponse          text,
  mediateur_info   boolean not null default false,
  created_at       timestamptz not null default now()
);
comment on table public.reclamations is 'GMB : réclamations, délais de 10 jours ouvrables, 15 jours ouvrables ou 2 mois (PAR-15, ADM-09).';

create table public.contestations (
  id               uuid primary key default gen_random_uuid(),
  client_id        uuid not null references public.clients(id) on delete cascade,
  operation_id     uuid not null references public.operations(id) on delete cascade,
  motif            text not null,
  montant          numeric(12,2) not null,
  statut           text not null default 'ouverte' check (statut in ('ouverte', 'remboursee', 'refusee', 'close')),
  rembourser_avant timestamptz not null,
  rembourse_le     timestamptz,
  created_at       timestamptz not null default now()
);
comment on table public.contestations is 'GMB : opérations non reconnues ; remboursement au plus tard la fin du jour ouvrable suivant (ADM-06).';

create table public.notifications (
  id                uuid primary key default gen_random_uuid(),
  client_id         uuid references public.clients(id) on delete cascade,
  destinataire_auth uuid references auth.users(id) on delete cascade,
  canal             text not null default 'in_app' check (canal in ('in_app', 'push', 'email', 'sms')),
  modele_code       text,
  titre             text not null,
  contenu           text not null,
  lien              text,
  lu_le             timestamptz,
  created_at        timestamptz not null default now(),
  check (client_id is not null or destinataire_auth is not null)
);
comment on table public.notifications is 'GMB : notifications in-app, push, e-mail et SMS.';
create index notifications_client_idx on public.notifications (client_id, created_at desc);
create index notifications_auth_idx on public.notifications (destinataire_auth, created_at desc);

create table public.appareils (
  id                   uuid primary key default gen_random_uuid(),
  client_id            uuid not null references public.clients(id) on delete cascade,
  nom                  text not null,
  plateforme           text check (plateforme in ('ios', 'android', 'web')),
  cle_publique         text,
  ajoute_le            timestamptz not null default now(),
  derniere_utilisation timestamptz,
  revoque_le           timestamptz
);
comment on table public.appareils is 'GMB : appareils de confiance GMB Pass (AUTH-04, AUTH-07).';

create table public.connexions (
  id          bigint generated always as identity primary key,
  client_id   uuid references public.clients(id) on delete cascade,
  identifiant char(8),
  espace      text not null default 'client' check (espace in ('client', 'dossier', 'backoffice')),
  resultat    text not null check (resultat in ('succes', 'echec_code', 'bloque', 'bloque_definitif', 'sca_refusee', 'grille_expiree')),
  appareil    text,
  created_at  timestamptz not null default now()
);
comment on table public.connexions is 'GMB : journal des connexions, 90 jours visibles par le client (AUTH-07).';
create index connexions_client_idx on public.connexions (client_id, created_at desc);


-- =============================================================================
-- 6. ESPACE PRO (PRO-01 à PRO-05)
-- =============================================================================
create table public.pro_clients (
  id         uuid primary key default gen_random_uuid(),
  client_id  uuid not null references public.clients(id) on delete cascade,
  nom        text not null,
  siren      text check (siren is null or siren ~ '^[0-9]{9}$'),
  email      extensions.citext,
  adresse    text,
  created_at timestamptz not null default now()
);
comment on table public.pro_clients is 'GMB : clients des indépendants, destinataires des factures (PRO-02).';

create table public.factures (
  id              uuid primary key default gen_random_uuid(),
  client_id       uuid not null references public.clients(id) on delete cascade,
  pro_client_id   uuid not null references public.pro_clients(id),
  numero          text not null,
  date_emission   date not null default current_date,
  date_echeance   date not null default current_date + 30,
  total_ht        numeric(12,2) not null default 0,
  total_tva       numeric(12,2) not null default 0,
  total_ttc       numeric(12,2) not null default 0,
  mention_tva     text,
  format          text not null default 'factur-x' check (format in ('factur-x', 'ubl', 'cii')),
  statut_cycle    text not null default 'brouillon'
                  check (statut_cycle in ('brouillon', 'deposee', 'rejetee', 'refusee', 'recue', 'approuvee', 'encaissee')),
  lien_paiement   text,
  provision_taux  numeric(5,2) not null default 25,
  provision_montant numeric(12,2) generated always as (round(total_ht * provision_taux / 100, 2)) stored,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (client_id, numero)
);
comment on table public.factures is 'GMB : factures électroniques et cycle de vie normalisé (PRO-02).';

create table public.facture_lignes (
  id             uuid primary key default gen_random_uuid(),
  facture_id     uuid not null references public.factures(id) on delete cascade,
  designation    text not null,
  quantite       numeric(10,2) not null check (quantite > 0),
  prix_unitaire  numeric(12,2) not null check (prix_unitaire >= 0),
  taux_tva       numeric(5,2) not null default 20 check (taux_tva in (0, 2.1, 5.5, 10, 20)),
  montant_ht     numeric(12,2) generated always as (round(quantite * prix_unitaire, 2)) stored,
  ordre          int not null default 0
);
comment on table public.facture_lignes is 'GMB : lignes de facture ; les totaux de la facture sont recalculés automatiquement.';


-- =============================================================================
-- 7. ESPACE BUSINESS (BIZ-01 à BIZ-08)
-- =============================================================================
create table public.entreprise_membres (
  entreprise_id uuid not null references public.entreprises(id) on delete cascade,
  client_id     uuid not null references public.clients(id) on delete cascade,
  role          text not null check (role in ('administrateur', 'responsable_financier', 'comptable', 'collaborateur', 'expert_comptable')),
  statut        text not null default 'actif' check (statut in ('invite', 'actif', 'revoque')),
  intitule      text,
  invite_le     timestamptz not null default now(),
  primary key (entreprise_id, client_id)
);
comment on table public.entreprise_membres is 'GMB : équipe et rôles d''une entreprise (BIZ-07).';

create table public.regles_approbation (
  id             uuid primary key default gen_random_uuid(),
  entreprise_id  uuid not null references public.entreprises(id) on delete cascade,
  type_operation text not null check (type_operation in ('virement', 'carte_virtuelle', 'note_de_frais')),
  seuil          numeric(14,2) not null default 0,
  nb_validations int not null default 1 check (nb_validations between 1 and 3),
  roles_valideurs text[] not null default '{administrateur}',
  actif          boolean not null default true,
  created_at     timestamptz not null default now()
);
comment on table public.regles_approbation is 'GMB : règles d''approbation par montant et type d''opération (BIZ-05).';

create table public.demandes_approbation (
  id            uuid primary key default gen_random_uuid(),
  entreprise_id uuid not null references public.entreprises(id) on delete cascade,
  regle_id      uuid references public.regles_approbation(id) on delete set null,
  type          text not null check (type in ('virement', 'carte_virtuelle', 'note_de_frais')),
  objet_id      uuid,
  libelle       text not null,
  montant       numeric(14,2) not null,
  demandeur_id  uuid not null references public.clients(id),
  statut        text not null default 'en_attente' check (statut in ('en_attente', 'validee', 'refusee', 'expiree')),
  expire_le     timestamptz not null default now() + interval '7 days',
  created_at    timestamptz not null default now()
);
comment on table public.demandes_approbation is 'GMB : demandes soumises au circuit d''approbation (BIZ-05).';

create table public.approbations (
  demande_id   uuid not null references public.demandes_approbation(id) on delete cascade,
  validateur_id uuid not null references public.clients(id),
  decision     text not null check (decision in ('validee', 'refusee')),
  sca_le       timestamptz not null default now(),
  commentaire  text,
  created_at   timestamptz not null default now(),
  primary key (demande_id, validateur_id)
);
comment on table public.approbations is 'GMB : décisions des valideurs ; un demandeur ne valide jamais sa propre demande.';

create table public.notes_de_frais (
  id                  uuid primary key default gen_random_uuid(),
  entreprise_id       uuid not null references public.entreprises(id) on delete cascade,
  client_id           uuid not null references public.clients(id),
  marchand            text not null,
  montant_ttc         numeric(12,2) not null check (montant_ttc > 0),
  tva                 numeric(12,2) not null default 0,
  date_depense        date not null,
  justificatif_chemin text,
  lecture_auto        jsonb not null default '{}'::jsonb,
  statut              text not null default 'soumise' check (statut in ('brouillon', 'soumise', 'validee', 'refusee', 'remboursee')),
  created_at          timestamptz not null default now()
);
comment on table public.notes_de_frais is 'GMB : notes de frais et lecture automatique des justificatifs (BIZ-06).';

create table public.cles_api (
  id            uuid primary key default gen_random_uuid(),
  entreprise_id uuid not null references public.entreprises(id) on delete cascade,
  nom           text not null,
  prefixe       text not null,                 -- seuls les premiers caractères sont affichés
  empreinte     text not null,                 -- empreinte SHA-256 : la clé complète n'est jamais stockée
  perimetres    text[] not null default '{comptes:lecture}',
  cree_le       timestamptz not null default now(),
  derniere_utilisation timestamptz,
  revoquee_le   timestamptz
);
comment on table public.cles_api is 'GMB : clés d''API Business, stockées sous forme d''empreinte (BIZ-08).';

create table public.webhooks (
  id               uuid primary key default gen_random_uuid(),
  entreprise_id    uuid not null references public.entreprises(id) on delete cascade,
  url              text not null check (url ~ '^https://'),
  evenements       text[] not null default '{operation.creee}',
  secret_empreinte text not null,
  actif            boolean not null default true,
  created_at       timestamptz not null default now()
);
comment on table public.webhooks is 'GMB : abonnements aux événements, signés HMAC (BIZ-08).';


-- =============================================================================
-- 8. ESPACE JEUNES (JEU-01 à JEU-04)
-- =============================================================================
create table public.comptes_jeunes (
  compte_id               uuid primary key references public.comptes(id) on delete cascade,
  jeune_client_id         uuid not null unique references public.clients(id) on delete cascade,
  parent_client_id        uuid not null references public.clients(id) on delete cascade,
  second_parent_client_id uuid references public.clients(id) on delete set null,
  plafond_hebdo           numeric(8,2) not null default 50 check (plafond_hebdo between 10 and 300),
  paiements_en_ligne      boolean not null default true,
  retraits                boolean not null default false,
  etranger                boolean not null default false,
  alerte_paiement         boolean not null default true,
  argent_de_poche_montant numeric(8,2) not null default 0 check (argent_de_poche_montant >= 0),
  argent_de_poche_jour    int check (argent_de_poche_jour between 1 and 7),   -- 1 = lundi … 7 = dimanche
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);
comment on table public.comptes_jeunes is 'GMB : comptes 10–17 ans et contrôles parentaux (JEU-04).';

create table public.defis (
  code        text primary key,
  titre       text not null,
  description text not null,
  objectif    numeric(10,2),
  recompense  int not null default 20,
  actif       boolean not null default true
);
comment on table public.defis is 'GMB : défis d''éducation financière récompensés en MoonPoints (JEU-02).';

create table public.defis_participations (
  defi_code   text not null references public.defis(code) on delete cascade,
  client_id   uuid not null references public.clients(id) on delete cascade,
  progression numeric(10,2) not null default 0,
  debut       date not null default current_date,
  termine_le  timestamptz,
  primary key (defi_code, client_id, debut)
);
comment on table public.defis_participations is 'GMB : progression des défis par jeune (JEU-02).';


-- =============================================================================
-- 9. BACK-OFFICE (ADM-01 à ADM-16)
-- =============================================================================
create table public.collaborateurs (
  id         uuid primary key references auth.users(id) on delete cascade,
  nom        text not null,
  email      extensions.citext,
  actif      boolean not null default true,
  created_at timestamptz not null default now()
);
comment on table public.collaborateurs is 'GMB : collaborateurs du back-office (ADM-13).';

create table public.roles_bo (
  code    text primary key,
  libelle text not null
);
comment on table public.roles_bo is 'GMB : rôles du back-office (chapitre 18).';

create table public.modules_bo (
  code    text primary key check (code ~ '^ADM-[0-9]{2}$'),
  libelle text not null,
  adresse text not null
);
comment on table public.modules_bo is 'GMB : les seize modules du back-office.';

create table public.collaborateur_roles (
  collaborateur_id uuid not null references public.collaborateurs(id) on delete cascade,
  role_code        text not null references public.roles_bo(code) on delete cascade,
  attribue_le      timestamptz not null default now(),
  primary key (collaborateur_id, role_code)
);
comment on table public.collaborateur_roles is 'GMB : rôles attribués à chaque collaborateur (ADM-13).';

create table public.habilitations (
  module_code text not null references public.modules_bo(code) on delete cascade,
  role_code   text not null references public.roles_bo(code) on delete cascade,
  droit       text not null check (droit in ('L', 'E', 'V', 'A')),
  primary key (module_code, role_code)
);
comment on table public.habilitations is 'GMB : matrice des habilitations L, E, V, A (chapitre 18).';

create table public.journal_audit (
  id             bigint generated always as identity primary key,
  horodatage     timestamptz not null default clock_timestamp(),
  acteur_id      uuid,
  acteur_type    text not null default 'systeme',
  action         text not null,
  objet_type     text not null,
  objet_id       text,
  avant          jsonb,
  apres          jsonb,
  motif          text,
  empreinte_prec text not null default '',
  empreinte      text not null default ''
);
comment on table public.journal_audit is 'GMB : journal d''audit chaîné par empreintes SHA-256, non modifiable (ADM-14).';
create index journal_audit_objet_idx on public.journal_audit (objet_type, objet_id);

create table public.alertes_lcbft (
  id          uuid primary key default gen_random_uuid(),
  personne_id uuid references public.personnes(id) on delete cascade,
  dossier_id  uuid references public.dossiers(id) on delete set null,
  client_id   uuid references public.clients(id) on delete set null,
  type        text not null check (type in ('gel_avoirs', 'ppe', 'pays_risque', 'scenario', 'revue_periodique')),
  gravite     text not null default 'moyenne' check (gravite in ('faible', 'moyenne', 'elevee')),
  statut      text not null default 'ouverte' check (statut in ('ouverte', 'en_analyse', 'classee', 'declaree')),
  details     jsonb not null default '{}'::jsonb,
  assigne_a   uuid,
  created_at  timestamptz not null default now(),
  traitee_le  timestamptz
);
comment on table public.alertes_lcbft is 'GMB : alertes de filtrage et de surveillance LCB-FT (ADM-05).';

create table public.alertes_fraude (
  id           uuid primary key default gen_random_uuid(),
  client_id    uuid references public.clients(id) on delete cascade,
  operation_id uuid references public.operations(id) on delete set null,
  type         text not null check (type in ('connexion_suspecte', 'operation_inhabituelle', 'contestation', 'refus_gmb_pass', 'escroquerie_virement')),
  score        int check (score between 0 and 100),
  statut       text not null default 'ouverte' check (statut in ('ouverte', 'en_analyse', 'classee', 'confirmee')),
  details      jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now(),
  traitee_le   timestamptz
);
comment on table public.alertes_fraude is 'GMB : alertes de fraude en temps réel (ADM-06).';

create table public.modeles_notification (
  code       text primary key,
  canal      text not null check (canal in ('in_app', 'push', 'email', 'sms', 'message_dossier')),
  sujet      text,
  contenu    text not null,
  variables  text[] not null default '{}',
  version    int not null default 1,
  actif      boolean not null default true,
  updated_at timestamptz not null default now()
);
comment on table public.modeles_notification is 'GMB : modèles de messages versionnés (ADM-10).';

create table public.parametres_securite (
  cle         text primary key,
  valeur      numeric not null,
  valeur_min  numeric not null,
  valeur_max  numeric not null,
  unite       text not null,
  description text not null,
  modifiable  boolean not null default true,
  modifie_par uuid,
  modifie_le  timestamptz not null default now(),
  check (valeur between valeur_min and valeur_max)
);
comment on table public.parametres_securite is 'GMB : paramètres de sécurité bornés par la réglementation (AUTH, ADM-12).';


-- =============================================================================
-- TABLES INTERNES (schéma gmb_prive, jamais exposées par l'API)
-- =============================================================================
-- Empreinte bcrypt du code secret à 8 chiffres (jamais le code lui-même)
create table gmb_prive.codes_clients (
  client_id  uuid primary key references public.clients(id) on delete cascade,
  code_hash  text not null,
  defini_le  timestamptz not null default now()
);


-- État de blocage par identifiant, connu ou non (aucune énumération possible)
create table gmb_prive.etat_connexion (
  identifiant        char(8) primary key,
  echecs_consecutifs int not null default 0,
  echecs_24h         int not null default 0,
  fenetre_24h_debut  timestamptz,
  bloque_jusqu       timestamptz,
  bloque_definitif   boolean not null default false,
  maj_le             timestamptz not null default now()
);

-- Grilles du clavier virtuel à usage unique (AUTH-03)
create table gmb_prive.grilles_clavier (
  id          uuid primary key default gen_random_uuid(),
  identifiant char(8) not null,
  disposition int[] not null,          -- 12 cases : chiffres 0 à 9, -1 case vide, -2 touche Effacer
  cree_le     timestamptz not null default now(),
  expire_le   timestamptz not null,
  utilisee    boolean not null default false
);
create index grilles_clavier_identifiant_idx on gmb_prive.grilles_clavier (identifiant, cree_le desc);


-- Numérotation continue des factures, par indépendant et par année
create table gmb_prive.compteurs_factures (
  client_id uuid not null references public.clients(id) on delete cascade,
  annee     int not null,
  dernier   int not null default 0,
  primary key (client_id, annee)
);


-- Coordonnées bancaires de collecte (premier versement, fonds reçus de l'extérieur)
create table public.parametres_banque (
  cle         text primary key,
  valeur      text not null default '',
  libelle     text not null,
  modifie_le  timestamptz not null default now()
);
comment on table public.parametres_banque is 'GMB : coordonnées du compte de collecte de GerMoonBank (premier versement, virements entrants) et paramètres texte.';


-- =============================================================================
-- 10. FONCTIONS D'ACCÈS (utilisées par les règles RLS)
-- L'espace de connexion est lu dans app_metadata.espace du jeton, que seul le
-- serveur peut écrire : 'dossier' (Mon Dossier), 'client' (Espace client) ou
-- 'backoffice'. Un compte Mon Dossier n'atteint jamais les comptes bancaires.
-- =============================================================================
create or replace function gmb_prive.espace() returns text
language sql stable security definer set search_path = '' as $$
  select case when auth.uid() is null then null
              else coalesce(auth.jwt() -> 'app_metadata' ->> 'espace', 'dossier') end
$$;

create or replace function gmb_prive.client_courant() returns uuid
language sql stable security definer set search_path = '' as $$
  select c.id from public.clients c
   where c.auth_user_id = auth.uid() and c.statut in ('actif', 'inactif') and gmb_prive.espace() = 'client'
$$;

create or replace function gmb_prive.est_collaborateur() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(gmb_prive.espace() = 'backoffice', false)
     and exists (select 1 from public.collaborateurs c where c.id = auth.uid() and c.actif)
$$;

create or replace function gmb_prive.a_role(p_role text) returns boolean
language sql stable security definer set search_path = '' as $$
  select gmb_prive.est_collaborateur()
     and exists (select 1 from public.collaborateur_roles r where r.collaborateur_id = auth.uid() and r.role_code = p_role)
$$;

create or replace function gmb_prive.droit_bo(p_module text, p_droits text[]) returns boolean
language sql stable security definer set search_path = '' as $$
  select gmb_prive.est_collaborateur() and exists (
    select 1 from public.collaborateur_roles r
      join public.habilitations h on h.role_code = r.role_code
     where r.collaborateur_id = auth.uid() and h.module_code = p_module and h.droit = any (p_droits))
$$;

create or replace function gmb_prive.bo_lecture(p_module text) returns boolean
language sql stable security definer set search_path = '' as $$ select gmb_prive.droit_bo(p_module, array['L', 'E', 'V', 'A']) $$;

create or replace function gmb_prive.bo_ecriture(p_module text) returns boolean
language sql stable security definer set search_path = '' as $$ select gmb_prive.droit_bo(p_module, array['E', 'A']) $$;

create or replace function gmb_prive.bo_decision(p_module text) returns boolean
language sql stable security definer set search_path = '' as $$ select gmb_prive.droit_bo(p_module, array['E', 'V', 'A']) $$;

create or replace function gmb_prive.dossier_du_demandeur(p_dossier uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(gmb_prive.espace() = 'dossier', false)
     and exists (select 1 from public.dossiers d where d.id = p_dossier and d.demandeur_auth = auth.uid())
$$;

create or replace function gmb_prive.membre_entreprise(p_entreprise uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.entreprise_membres m
                  where m.entreprise_id = p_entreprise and m.client_id = gmb_prive.client_courant() and m.statut = 'actif')
$$;

create or replace function gmb_prive.role_entreprise(p_entreprise uuid) returns text
language sql stable security definer set search_path = '' as $$
  select m.role from public.entreprise_membres m
   where m.entreprise_id = p_entreprise and m.client_id = gmb_prive.client_courant() and m.statut = 'actif'
$$;

create or replace function gmb_prive.compte_accessible(p_compte uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.comptes c
     where c.id = p_compte and (
           c.client_id = gmb_prive.client_courant()
        or (c.entreprise_id is not null and gmb_prive.membre_entreprise(c.entreprise_id))
        or exists (select 1 from public.comptes_jeunes j
                    where j.compte_id in (c.id, c.compte_parent_id)
                      and gmb_prive.client_courant() in (j.parent_client_id, j.second_parent_client_id))))
$$;

create or replace function gmb_prive.carte_accessible(p_carte uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.cartes k join public.comptes c on c.id = k.compte_id
     where k.id = p_carte and (
           k.titulaire_client_id = gmb_prive.client_courant()
        or exists (select 1 from public.comptes_jeunes j where j.compte_id = c.id
                    and gmb_prive.client_courant() in (j.parent_client_id, j.second_parent_client_id))
        or (c.entreprise_id is not null and gmb_prive.role_entreprise(c.entreprise_id) in ('administrateur', 'responsable_financier'))))
$$;

create or replace function gmb_prive.client_visible(p_client uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_client = gmb_prive.client_courant()
      or exists (select 1 from public.comptes_jeunes j where j.jeune_client_id = p_client
                  and gmb_prive.client_courant() in (j.parent_client_id, j.second_parent_client_id))
      or exists (select 1 from public.comptes_jeunes j where j.jeune_client_id = gmb_prive.client_courant()
                  and p_client in (j.parent_client_id, j.second_parent_client_id))
      or exists (select 1 from public.entreprise_membres m join public.entreprise_membres moi on moi.entreprise_id = m.entreprise_id
                  where m.client_id = p_client and moi.client_id = gmb_prive.client_courant() and moi.statut = 'actif')
$$;

create or replace function gmb_prive.personne_accessible(p_personne uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select (coalesce(gmb_prive.espace() = 'dossier', false)
          and exists (select 1 from public.dossiers d where d.personne_id = p_personne and d.demandeur_auth = auth.uid()))
      or exists (select 1 from public.clients c where c.personne_id = p_personne and gmb_prive.client_visible(c.id))
$$;

-- Notification interne (in-app, push, e-mail ou SMS)
create or replace function gmb_prive.notifier(p_client uuid, p_auth uuid, p_titre text, p_contenu text,
                                              p_lien text default null, p_canal text default 'in_app', p_modele text default null)
returns void language sql security definer set search_path = '' as $$
  insert into public.notifications (client_id, destinataire_auth, canal, modele_code, titre, contenu, lien)
  values (p_client, coalesce(p_auth, (select auth_user_id from public.clients where id = p_client)), p_canal, p_modele, p_titre, p_contenu, p_lien)
$$;

-- Montant au format français (42,10)
create or replace function gmb_prive.euros(p_montant numeric) returns text
language sql immutable set search_path = '' as $$
  select replace(to_char(p_montant, 'FM999999999990.00'), '.', ',')
$$;


-- =============================================================================
-- 11. FONCTIONS MÉTIER (RPC appelées par le site : supabase.rpc('gmb_…'))
-- Chaque fonction vérifie elle-même l'identité et les droits de l'appelant.
-- =============================================================================

-- ---------- 11.1 Vitrine (accessibles sans connexion) ------------------------

-- Simulateur de prêt personnel (VIT-15, PAR-12)
create or replace function public.gmb_simuler_credit(p_montant numeric, p_duree int, p_objet text default 'tous')
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare g record; m numeric;
begin
  select * into g from public.grilles_credit
   where actif and valide_conformite and produit = 'pret_personnel'
     and p_montant between montant_min and montant_max and p_duree between duree_min and duree_max
     and objet in (coalesce(p_objet, 'tous'), 'tous')
   order by (objet = coalesce(p_objet, 'tous')) desc, date_effet desc
   limit 1;
  if not found then
    return jsonb_build_object('disponible', false, 'message', 'Aucune offre pour ce montant et cette durée.');
  end if;
  m := gmb_prive.mensualite(p_montant, g.taux_debiteur, p_duree);
  return jsonb_build_object(
    'disponible', true, 'montant', p_montant, 'duree_mois', p_duree, 'objet', coalesce(p_objet, 'tous'),
    'taux_debiteur', g.taux_debiteur, 'taeg', gmb_prive.taeg(g.taux_debiteur), 'mensualite', m,
    'montant_total_du', m * p_duree, 'cout_total', m * p_duree - p_montant, 'frais_dossier', 0,
    'mention', (select contenu from public.cms_textes_legaux where code = 'LEG-CREDIT-01'));
end $$;

-- Simulateur d'épargne du Livret GMB (VIT-01, VIT-11)
create or replace function public.gmb_simuler_epargne(p_montant numeric, p_formule text default 'zenith', p_jours int default 365)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare t numeric;
begin
  select taux_livret into t from public.formules where code = p_formule and actif;
  if t is null then return jsonb_build_object('disponible', false); end if;
  if p_montant < 10 or p_montant > 100000 then
    raise exception 'Le montant doit être compris entre 10 € et 100 000 €.' using errcode = '22023';
  end if;
  return jsonb_build_object('disponible', true, 'taux_brut', t, 'jours', p_jours,
                            'interets', round(p_montant * t / 100 * p_jours / 365, 2),
                            'par_jour', round(p_montant * t / 100 / 365, 2));
end $$;

-- Clavier virtuel : nouvelle grille à usage unique (AUTH-03).
-- Toujours une grille, que l'identifiant existe ou non (aucune énumération).
-- La disposition n'est remise qu'à la fonction serveur gmb-connexion, qui la
-- transforme en images : le navigateur ne reçoit jamais les chiffres (AUTH-03).
create or replace function public.gmb_clavier_nouveau(p_identifiant text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_ttl int; v_disp int[]; v_id uuid; v_exp timestamptz;
begin
  if p_identifiant is null or p_identifiant !~ '^[0-9]{8}$' then
    raise exception 'L''identifiant comporte 8 chiffres.' using errcode = '22023';
  end if;
  if (select count(*) from gmb_prive.grilles_clavier where identifiant = p_identifiant and cree_le > now() - interval '1 minute') >= 10 then
    raise exception 'Trop de tentatives. Patientez une minute.' using errcode = '54000';
  end if;
  select coalesce((select valeur::int from public.parametres_securite where cle = 'grille_ttl_secondes'), 120) into v_ttl;
  select array_agg(x order by random()) into v_disp from generate_series(0, 9) as x;
  -- 12 cases : 9 chiffres, case vide en bas à gauche, 1 chiffre, touche Effacer en bas à droite
  v_disp := v_disp[1:9] || array[-1, v_disp[10], -2];
  v_exp := now() + make_interval(secs => v_ttl);
  insert into gmb_prive.grilles_clavier (identifiant, disposition, expire_le)
  values (p_identifiant, v_disp, v_exp) returning id into v_id;
  return jsonb_build_object('grille', v_id, 'touches', to_jsonb(v_disp), 'expire_le', v_exp);
end $$;


-- ---------- 11.2 Fonctions réservées au serveur (clé secrète, Edge Functions) --

-- Vérification du code à partir des positions touchées (AUTH-03).
-- 3 échecs consécutifs : blocage 30 min ; 6 échecs en 24 h : blocage complet.
create or replace function public.gmb_clavier_verifier(p_grille uuid, p_positions int[])
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare g record; e record; v_code text := ''; p int; v_hash text; v_client uuid; v_auth uuid;
        v_max int; v_bloc int; v_max24 int;
begin
  select * into g from gmb_prive.grilles_clavier where id = p_grille for update;
  if not found or g.utilisee or g.expire_le < now() then
    return jsonb_build_object('statut', 'grille_expiree');
  end if;
  update gmb_prive.grilles_clavier set utilisee = true where id = p_grille;
  if coalesce(array_length(p_positions, 1), 0) <> 8 then
    return jsonb_build_object('statut', 'format');
  end if;
  foreach p in array p_positions loop
    if p < 1 or p > 12 or g.disposition[p] < 0 then
      return jsonb_build_object('statut', 'format');
    end if;
    v_code := v_code || g.disposition[p]::text;
  end loop;

  select coalesce(max(valeur) filter (where cle = 'echecs_avant_blocage'), 3)::int,
         coalesce(max(valeur) filter (where cle = 'blocage_minutes'), 30)::int,
         coalesce(max(valeur) filter (where cle = 'echecs_24h_blocage_definitif'), 6)::int
    into v_max, v_bloc, v_max24
    from public.parametres_securite;

  insert into gmb_prive.etat_connexion (identifiant) values (g.identifiant) on conflict (identifiant) do nothing;
  select * into e from gmb_prive.etat_connexion where identifiant = g.identifiant for update;

  select c.id, c.auth_user_id, k.code_hash into v_client, v_auth, v_hash
    from public.clients c left join gmb_prive.codes_clients k on k.client_id = c.id
   where c.identifiant = g.identifiant and c.statut in ('actif', 'inactif');

  if e.bloque_definitif then
    insert into public.connexions (client_id, identifiant, resultat) values (v_client, g.identifiant, 'bloque_definitif');
    return jsonb_build_object('statut', 'bloque_definitif');
  end if;
  if e.bloque_jusqu is not null and e.bloque_jusqu > now() then
    insert into public.connexions (client_id, identifiant, resultat) values (v_client, g.identifiant, 'bloque');
    return jsonb_build_object('statut', 'bloque', 'bloque_jusqu', e.bloque_jusqu);
  end if;
  if e.fenetre_24h_debut is null or e.fenetre_24h_debut < now() - interval '24 hours' then
    e.echecs_24h := 0;
    e.fenetre_24h_debut := now();
  end if;

  if v_hash is not null and extensions.crypt(v_code, v_hash) = v_hash then
    update gmb_prive.etat_connexion
       set echecs_consecutifs = 0, bloque_jusqu = null, echecs_24h = e.echecs_24h,
           fenetre_24h_debut = e.fenetre_24h_debut, maj_le = now()
     where identifiant = g.identifiant;
    insert into public.connexions (client_id, identifiant, resultat) values (v_client, g.identifiant, 'succes');
    return jsonb_build_object('statut', 'ok', 'client_id', v_client, 'auth_user_id', v_auth);
  end if;

  e.echecs_consecutifs := e.echecs_consecutifs + 1;
  e.echecs_24h := e.echecs_24h + 1;
  if e.echecs_24h >= v_max24 then
    e.bloque_definitif := true;
  elsif e.echecs_consecutifs >= v_max then
    e.bloque_jusqu := now() + make_interval(mins => v_bloc);
    e.echecs_consecutifs := 0;
  end if;
  update gmb_prive.etat_connexion
     set echecs_consecutifs = e.echecs_consecutifs, echecs_24h = e.echecs_24h, fenetre_24h_debut = e.fenetre_24h_debut,
         bloque_jusqu = e.bloque_jusqu, bloque_definitif = e.bloque_definitif, maj_le = now()
   where identifiant = g.identifiant;
  insert into public.connexions (client_id, identifiant, resultat) values (v_client, g.identifiant, 'echec_code');

  if v_client is not null and (e.bloque_definitif or (e.bloque_jusqu is not null and e.bloque_jusqu > now())) then
    perform gmb_prive.notifier(v_client, null, 'Accès bloqué par sécurité',
      'Plusieurs codes erronés ont été saisis. Si ce n''était pas vous, contactez-nous.', null, 'email', 'MSG-CONNEXION-BLOQUEE');
  end if;
  if e.bloque_definitif then
    return jsonb_build_object('statut', 'bloque_definitif');
  end if;
  if e.bloque_jusqu is not null and e.bloque_jusqu > now() then
    return jsonb_build_object('statut', 'bloque', 'bloque_jusqu', e.bloque_jusqu);
  end if;
  return jsonb_build_object('statut', 'echec', 'essais_restants', least(v_max - e.echecs_consecutifs, v_max24 - e.echecs_24h),
                            'blocage_minutes', v_bloc);
end $$;

-- Règles de solidité d'un code secret à 8 chiffres : renvoie le motif du refus, ou
-- null s'il est accepté (suites, répétitions et date de naissance refusées)
create or replace function gmb_prive.code_secret_probleme(p_client uuid, p_code text) returns text
language plpgsql stable security definer set search_path = '' as $$
declare v_naissance date;
begin
  if p_code is null or p_code !~ '^[0-9]{8}$' then
    return 'Le code secret comporte 8 chiffres.';
  end if;
  if p_code ~ '^(.)\1{7}$' or position(p_code in '01234567890123') > 0 or position(p_code in '98765432109876') > 0 then
    return 'Ce code est trop simple : évitez les suites et les répétitions.';
  end if;
  select p.date_naissance into v_naissance from public.clients c join public.personnes p on p.id = c.personne_id where c.id = p_client;
  if v_naissance is not null and p_code in (to_char(v_naissance, 'DDMMYYYY'), to_char(v_naissance, 'YYYYMMDD')) then
    return 'Votre code ne doit pas être votre date de naissance.';
  end if;
  return null;
end $$;

-- Définition du code secret à 8 chiffres (suites, répétitions et date de naissance refusées)
create or replace function gmb_prive.definir_code(p_client uuid, p_code text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_probleme text := gmb_prive.code_secret_probleme(p_client, p_code);
begin
  if v_probleme is not null then
    raise exception '%', v_probleme using errcode = '22023';
  end if;
  insert into gmb_prive.codes_clients (client_id, code_hash)
  values (p_client, extensions.crypt(p_code, extensions.gen_salt('bf', 10)))
  on conflict (client_id) do update set code_hash = excluded.code_hash, defini_le = now();
end $$;

-- Contrôle d'un code secret par la fonction serveur, avant d'utiliser le code reçu par
-- e-mail : un code refusé ne fait pas perdre le code e-mail, qui ne sert qu'une fois
create or replace function public.gmb_code_secret_controler(p_identifiant text, p_code text)
returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('probleme',
    gmb_prive.code_secret_probleme((select id from public.clients where identifiant = p_identifiant), p_code))
$$;

-- Première connexion (AUTH-05) : code d'activation, création du code secret,
-- rattachement du compte de connexion. Appelée par l'Edge Function d'activation.
create or replace function public.gmb_activer_client(p_identifiant text, p_nouveau_code text, p_auth_user uuid)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_client uuid; v_lie uuid;
begin
  select id, auth_user_id into v_client, v_lie from public.clients where identifiant = p_identifiant and statut = 'actif';
  if v_client is null then
    return jsonb_build_object('statut', 'inconnu');
  end if;
  if v_lie is not null then
    return jsonb_build_object('statut', 'deja_active');
  end if;
  perform gmb_prive.definir_code(v_client, p_nouveau_code);
  update auth.users set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"espace": "client"}'::jsonb where id = p_auth_user;
  update public.clients set auth_user_id = p_auth_user where id = v_client;
  return jsonb_build_object('statut', 'ok', 'client_id', v_client);
end $$;

-- Intérêts quotidiens du Livret GMB (tâche planifiée chaque nuit)
create or replace function public.gmb_calculer_interets(p_jour date default current_date - 1)
returns int language plpgsql volatile security definer set search_path = '' as $$
declare c record; m numeric; n int := 0;
begin
  for c in select id, solde, taux from public.comptes
            where type = 'livret' and statut = 'actif' and solde > 0 and coalesce(taux, 0) > 0 loop
    m := round(c.solde * c.taux / 100 / 365, 2);
    if m > 0 and not exists (select 1 from public.interets where compte_id = c.id and jour = p_jour) then
      insert into public.interets (compte_id, jour, solde_base, taux, montant) values (c.id, p_jour, c.solde, c.taux, m);
      insert into public.operations (compte_id, type, libelle, montant, categorie_code, date_operation, date_valeur)
      values (c.id, 'interets', 'Intérêts du ' || to_char(p_jour, 'DD/MM/YYYY'), m, 'epargne', p_jour + time '23:59', p_jour);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- Demandes d'approbation non traitées : expiration après 7 jours (BIZ-05)
create or replace function public.gmb_expirer_approbations()
returns int language plpgsql volatile security definer set search_path = '' as $$
declare n int;
begin
  with expirees as (
    update public.demandes_approbation set statut = 'expiree'
     where statut = 'en_attente' and expire_le < now()
    returning type, objet_id)
  update public.virements v set statut = 'annule', motif_rejet = 'Approbation expirée'
    from expirees e where e.type = 'virement' and v.id = e.objet_id and v.statut = 'en_approbation';
  get diagnostics n = row_count;
  return n;
end $$;

-- Données des demandeurs : anonymisation après 12 mois (abandon, renonciation)
-- ou 5 ans (refus, conservation LCB-FT). Les clients ne sont jamais concernés.
create or replace function public.gmb_purger_prospects()
returns int language plpgsql volatile security definer set search_path = '' as $$
declare n int;
begin
  with cibles as (
    select d.id, d.personne_id from public.dossiers d
     where (d.etat in ('abandonne', 'renonciation') and d.updated_at < now() - interval '12 months')
        or (d.etat in ('refuse', 'refusee') and d.updated_at < now() - interval '5 years')),
  archives as (
    update public.dossiers set etat = 'archive' where id in (select id from cibles) returning id)
  update public.personnes p
     set prenoms = 'Anonymisé', nom_naissance = null, nom_usage = null, email = null, telephone = null,
         adresse_ligne1 = null, adresse_ligne2 = null, date_naissance = null, nif = null
   where p.id in (select personne_id from cibles)
     and not exists (select 1 from public.clients c where c.personne_id = p.id);
  get diagnostics n = row_count;
  return n;
end $$;

-- Publication des pages programmées (ADM-02)
create or replace function public.gmb_publier_planifiees()
returns int language plpgsql volatile security definer set search_path = '' as $$
declare n int;
begin
  update public.cms_pages set statut = 'publiee'
   where statut = 'planifiee' and planifiee_le is not null and planifiee_le <= now();
  get diagnostics n = row_count;
  return n;
end $$;


-- ---------- 11.3 Espace Mon Dossier (compte e-mail et mot de passe) ----------

-- Nouvelle demande d'ouverture de compte ou de crédit (ONB-01, ONB-C). Une demande de
-- même nature et de même profil, encore à l'état de brouillon, est reprise : la personne
-- ne se retrouve jamais avec deux demandes identiques en cours.
create or replace function public.gmb_dossier_creer(p_type text default 'ouverture', p_segment text default 'particulier',
                                                    p_formule text default 'luna')
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_personne uuid; v_dossier uuid; v_ref text;
begin
  if auth.uid() is null or gmb_prive.espace() <> 'dossier' then
    raise exception 'Connectez-vous à l''Espace Mon Dossier pour déposer une demande.' using errcode = '42501';
  end if;
  if p_type not in ('ouverture', 'credit') then
    raise exception 'Type de demande inconnu.' using errcode = '22023';
  end if;
  if p_segment not in ('particulier', 'pro', 'business', 'jeunes') then
    raise exception 'Profil inconnu.' using errcode = '22023';
  end if;
  if p_type = 'ouverture' and not exists (select 1 from public.formules where code = p_formule) then
    raise exception 'Cette formule n''existe pas : choisissez une formule de la liste.' using errcode = '22023';
  end if;
  select id, reference into v_dossier, v_ref from public.dossiers
   where demandeur_auth = auth.uid() and type = p_type and segment = p_segment and etat = 'brouillon'
   order by created_at desc limit 1;
  if v_dossier is not null then
    update public.dossiers
       set formule_code = case when p_type = 'ouverture' then p_formule else formule_code end, derniere_activite = now()
     where id = v_dossier;
    return jsonb_build_object('dossier', v_dossier, 'reference', v_ref, 'repris', true);
  end if;
  select personne_id into v_personne from public.dossiers
   where demandeur_auth = auth.uid() and personne_id is not null order by created_at limit 1;
  if v_personne is null then
    insert into public.personnes (email) values (auth.jwt() ->> 'email') returning id into v_personne;
  end if;
  v_ref := gmb_prive.reference(case when p_type = 'credit' then 'CRE' else 'OUV' end);
  insert into public.dossiers (reference, type, segment, formule_code, demandeur_auth, personne_id)
  values (v_ref, p_type, p_segment, case when p_type = 'ouverture' then p_formule end, auth.uid(), v_personne)
  returning id into v_dossier;
  insert into public.dossier_evenements (dossier_id, etat_apres, acteur, libelle_client)
  values (v_dossier, 'brouillon', 'client', 'Demande créée');
  if p_type = 'ouverture' then
    insert into public.dossier_pieces (dossier_id, type) values (v_dossier, 'piece_identite'), (v_dossier, 'selfie');
    if p_segment = 'business' then
      -- Société : Kbis, statuts et déclaration des bénéficiaires effectifs
      insert into public.dossier_pieces (dossier_id, type) values (v_dossier, 'kbis'), (v_dossier, 'statuts'), (v_dossier, 'beneficiaires_effectifs');
    else
      insert into public.dossier_pieces (dossier_id, type) values (v_dossier, 'justificatif_domicile');
      if p_segment = 'pro' then
        -- Entrepreneur : justificatif d'immatriculation (Kbis, avis SIRENE ou extrait RNE)
        insert into public.dossier_pieces (dossier_id, type) values (v_dossier, 'kbis');
      end if;
      if p_segment = 'jeunes' then
        -- Parent d'un mineur : preuve du lien de filiation (livret de famille ou acte de naissance)
        insert into public.dossier_pieces (dossier_id, type) values (v_dossier, 'lien_filiation');
      end if;
    end if;
  else
    insert into public.dossier_pieces (dossier_id, type) values (v_dossier, 'piece_identite'), (v_dossier, 'justificatif_revenus');
  end if;
  return jsonb_build_object('dossier', v_dossier, 'reference', v_ref, 'repris', false);
end $$;

-- GerMoonBank · installation de la base, partie 3 sur 8
-- Exécutez les parties dans l'ordre, chacune dans une requête vide du SQL Editor.
-- Contenu : 03_fonctions
-- Identité et situation (ONB-04, ONB-05). Une valeur absente ou vide ne remplace jamais
-- une valeur déjà saisie ; seuls le nom d'usage et le complément d'adresse, facultatifs,
-- peuvent être effacés en les envoyant vides.
create or replace function public.gmb_dossier_maj_personne(p_dossier uuid, p_donnees jsonb)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare v_personne uuid; v_etat text; v_segment text; v_naissance date; d jsonb;
begin
  if not gmb_prive.dossier_du_demandeur(p_dossier) then
    raise exception 'Dossier introuvable.' using errcode = '42501';
  end if;
  select personne_id, etat, segment into v_personne, v_etat, v_segment from public.dossiers where id = p_dossier;
  if v_etat not in ('brouillon', 'incomplet') then
    raise exception 'Ce dossier ne peut plus être modifié.' using errcode = '55000';
  end if;
  -- Les textes vides deviennent « absents » : aucune chaîne vide n'est enregistrée
  select coalesce(jsonb_object_agg(cle, case when jsonb_typeof(valeur) = 'string' and btrim(valeur #>> '{}') = '' then 'null'::jsonb else valeur end), '{}'::jsonb)
    into d from jsonb_each(coalesce(p_donnees, '{}'::jsonb)) as x(cle, valeur);
  update public.personnes set
    civilite           = coalesce(d ->> 'civilite', civilite),
    nom_naissance      = coalesce(btrim(d ->> 'nom_naissance'), nom_naissance),
    nom_usage          = case when p_donnees ? 'nom_usage' then btrim(d ->> 'nom_usage') else nom_usage end,
    prenoms            = coalesce(btrim(d ->> 'prenoms'), prenoms),
    date_naissance     = coalesce((d ->> 'date_naissance')::date, date_naissance),
    lieu_naissance     = coalesce(btrim(d ->> 'lieu_naissance'), lieu_naissance),
    pays_naissance     = coalesce(d ->> 'pays_naissance', pays_naissance),
    nationalite        = coalesce(d ->> 'nationalite', nationalite),
    telephone          = coalesce(d ->> 'telephone', telephone),
    adresse_ligne1     = coalesce(btrim(d ->> 'adresse_ligne1'), adresse_ligne1),
    adresse_ligne2     = case when p_donnees ? 'adresse_ligne2' then btrim(d ->> 'adresse_ligne2') else adresse_ligne2 end,
    code_postal        = coalesce(d ->> 'code_postal', code_postal),
    ville              = coalesce(btrim(d ->> 'ville'), ville),
    pays               = coalesce(d ->> 'pays', pays),
    profession         = coalesce(d ->> 'profession', profession),
    revenus_tranche    = coalesce(d ->> 'revenus_tranche', revenus_tranche),
    patrimoine_tranche = coalesce(d ->> 'patrimoine_tranche', patrimoine_tranche),
    origine_fonds      = coalesce(d ->> 'origine_fonds', origine_fonds),
    residence_fiscale  = coalesce(d ->> 'residence_fiscale', residence_fiscale),
    nif                = coalesce(d ->> 'nif', nif),
    personne_us        = coalesce((d ->> 'personne_us')::boolean, personne_us),
    ppe_declaree       = coalesce((d ->> 'ppe_declaree')::boolean, ppe_declaree)
  where id = v_personne
  returning date_naissance into v_naissance;
  if v_segment <> 'jeunes' and v_naissance is not null and v_naissance > current_date - interval '18 years' then
    raise exception 'L''ouverture en ligne est réservée aux personnes majeures.' using errcode = '22023';
  end if;
  update public.dossiers
     set etape_tunnel = greatest(etape_tunnel, least(11, coalesce((d ->> 'etape')::int, etape_tunnel))),
         derniere_activite = now()
   where id = p_dossier;
end $$;

-- Consentements horodatés (CGU, confidentialité, biométrie, FICP…)
create or replace function public.gmb_dossier_consentir(p_dossier uuid, p_type text, p_version text, p_accorde boolean)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if not gmb_prive.dossier_du_demandeur(p_dossier) then
    raise exception 'Dossier introuvable.' using errcode = '42501';
  end if;
  insert into public.consentements (auth_user_id, personne_id, type, version, accorde, source)
  values (auth.uid(), (select personne_id from public.dossiers where id = p_dossier), p_type, p_version, p_accorde, 'mon_dossier');
  if p_type = 'ficp' then
    update public.dossier_credit set consentement_ficp = p_accorde where dossier_id = p_dossier;
  end if;
end $$;

-- Dépôt ou remplacement d'une pièce (ONB-07, ONB-08, DOS-04)
create or replace function public.gmb_dossier_piece_deposer(p_dossier uuid, p_type text, p_chemin text,
                                                            p_empreinte text default null, p_date_document date default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_etat text; v_type text; v_reste int;
begin
  if not gmb_prive.dossier_du_demandeur(p_dossier) then
    raise exception 'Dossier introuvable.' using errcode = '42501';
  end if;
  select etat, type into v_etat, v_type from public.dossiers where id = p_dossier for update;
  if v_etat not in ('brouillon', 'incomplet') then
    raise exception 'Ce dossier ne peut plus recevoir de pièce.' using errcode = '55000';
  end if;
  if p_chemin is null or split_part(p_chemin, '/', 1) <> auth.uid()::text then
    raise exception 'Fichier invalide : déposez-le dans votre espace sécurisé.' using errcode = '22023';
  end if;
  update public.dossier_pieces
     set statut = 'deposee', fichier_chemin = p_chemin, empreinte_sha256 = p_empreinte, date_document = p_date_document,
         depose_le = now(), motif_refus_client = null
   where dossier_id = p_dossier and type = p_type and statut in ('attendue', 'refusee', 'facultative', 'deposee');
  if not found then
    insert into public.dossier_pieces (dossier_id, type, statut, fichier_chemin, empreinte_sha256, date_document, depose_le)
    values (p_dossier, p_type, 'deposee', p_chemin, p_empreinte, p_date_document, now());
  end if;
  update public.dossiers set derniere_activite = now() where id = p_dossier;
  select count(*) into v_reste from public.dossier_pieces where dossier_id = p_dossier and statut in ('attendue', 'refusee');
  if v_etat = 'incomplet' and v_reste = 0 then
    update public.dossiers set etat = case when v_type = 'credit' then 'analyse' else 'en_verification' end where id = p_dossier;
  end if;
  return jsonb_build_object('pieces_restantes', v_reste);
end $$;

-- Premier versement depuis un compte au nom du demandeur (ONB-10) : le titulaire du
-- compte émetteur doit porter son nom de naissance ou son nom d'usage
create or replace function public.gmb_dossier_premier_versement(p_dossier uuid, p_montant numeric, p_moyen text default 'virement', p_nom_titulaire text default null)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_nom text; v_usage text; v_titulaire text; v_ref text; v_collecte jsonb; v_segment text; v_societe text;
begin
  if not gmb_prive.dossier_du_demandeur(p_dossier) then
    raise exception 'Dossier introuvable.' using errcode = '42501';
  end if;
  if p_montant is null or p_montant < 10 or p_montant > 1000 then
    raise exception 'Le premier versement est compris entre 10 € et 1 000 €.' using errcode = '22023';
  end if;
  if coalesce(p_moyen, 'virement') <> 'virement' then
    raise exception 'Le premier versement se fait par virement.' using errcode = '22023';
  end if;
  select coalesce(jsonb_object_agg(cle, valeur), '{}'::jsonb) into v_collecte from public.parametres_banque where cle like 'collecte%';
  if coalesce(v_collecte ->> 'collecte_iban', '') = '' then
    raise exception 'Le compte qui reçoit les versements n''est pas encore renseigné par GerMoonBank. Votre demande est enregistrée : revenez un peu plus tard pour la terminer.' using errcode = '55000';
  end if;
  select gmb_prive.normaliser_nom(p.nom_naissance), gmb_prive.normaliser_nom(p.nom_usage), d.reference, d.segment, gmb_prive.nom_societe(e.raison_sociale)
    into v_nom, v_usage, v_ref, v_segment, v_societe
    from public.dossiers d join public.personnes p on p.id = d.personne_id
    left join public.dossier_entreprises e on e.dossier_id = d.id where d.id = p_dossier;
  v_titulaire := gmb_prive.nom_societe(p_nom_titulaire);
  if coalesce(v_nom, '') = '' and coalesce(v_usage, '') = '' then
    raise exception 'Renseignez d''abord votre identité (étape 1).' using errcode = '55000';
  end if;
  if coalesce(v_titulaire, '') = '' then
    raise exception 'Indiquez le titulaire du compte d''où part le virement.' using errcode = '22023';
  end if;
  if v_segment = 'business' then
    if coalesce(v_societe, '') = '' then
      raise exception 'Renseignez d''abord les informations de votre entreprise.' using errcode = '55000';
    end if;
    if position(v_societe in v_titulaire) = 0 then
      raise exception 'Le virement doit partir d''un compte au nom de l''entreprise.' using errcode = '22023';
    end if;
  elsif not ((v_nom <> '' and position(v_nom in v_titulaire) > 0) or (v_usage <> '' and position(v_usage in v_titulaire) > 0))
        and (coalesce(v_societe, '') = '' or position(v_societe in v_titulaire) = 0) then
    raise exception 'Le compte d''où part le virement doit être à votre nom.' using errcode = '22023';
  end if;
  insert into public.premiers_versements (dossier_id, montant, moyen, nom_titulaire, statut, declare_le)
  values (p_dossier, p_montant, 'virement', btrim(p_nom_titulaire), 'attendu', now())
  on conflict (dossier_id) do update set montant = excluded.montant, nom_titulaire = excluded.nom_titulaire, declare_le = now()
    where public.premiers_versements.statut = 'attendu';
  return jsonb_build_object('statut', 'attendu', 'montant', p_montant, 'reference', v_ref,
    'titulaire', v_collecte ->> 'collecte_titulaire', 'iban', v_collecte ->> 'collecte_iban',
    'bic', v_collecte ->> 'collecte_bic', 'banque', v_collecte ->> 'collecte_banque');
end $$;

-- Réception du premier versement, constatée par la trésorerie (ADM-16)
create or replace function public.gmb_bo_versement_recu(p_dossier uuid, p_montant_recu numeric, p_titulaire_constate text default null)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v record; v_nom text; v_usage text; v_societe text; v_segment text; v_constate text := gmb_prive.nom_societe(p_titulaire_constate); v_conforme boolean;
begin
  if not gmb_prive.bo_decision('ADM-16') then
    raise exception 'Droits insuffisants : la réception d''un versement relève de la trésorerie.' using errcode = '42501';
  end if;
  select * into v from public.premiers_versements where dossier_id = p_dossier for update;
  if not found then
    raise exception 'Aucun premier versement n''est déclaré pour ce dossier.' using errcode = '55000';
  end if;
  if v.statut <> 'attendu' then
    raise exception 'Ce versement a déjà été traité.' using errcode = '55000';
  end if;
  if p_montant_recu is null or p_montant_recu <= 0 then
    raise exception 'Indiquez le montant effectivement reçu.' using errcode = '22023';
  end if;
  if coalesce(v_constate, '') <> '' then
    select d.segment, gmb_prive.nom_societe(e.raison_sociale), gmb_prive.normaliser_nom(p.nom_naissance), gmb_prive.normaliser_nom(p.nom_usage)
      into v_segment, v_societe, v_nom, v_usage
      from public.dossiers d join public.personnes p on p.id = d.personne_id
      left join public.dossier_entreprises e on e.dossier_id = d.id where d.id = p_dossier;
    v_conforme := case when v_segment = 'business' then coalesce(v_societe, '') <> '' and position(v_societe in v_constate) > 0
                       else (coalesce(v_nom, '') <> '' and position(v_nom in v_constate) > 0)
                         or (coalesce(v_usage, '') <> '' and position(v_usage in v_constate) > 0)
                         or (coalesce(v_societe, '') <> '' and position(v_societe in v_constate) > 0) end;
    if not coalesce(v_conforme, false) then
      raise exception 'Le virement reçu ne vient pas d''un compte au nom du demandeur : refusez-le et remboursez-le.' using errcode = '22023';
    end if;
  end if;
  update public.premiers_versements set statut = 'recu', montant_recu = p_montant_recu, recu_le = now() where dossier_id = p_dossier;
  insert into public.dossier_controles (dossier_id, controle, resultat, details)
  values (p_dossier, 'premier_versement', 'conforme', jsonb_build_object('montant_recu', p_montant_recu, 'titulaire', coalesce(nullif(btrim(coalesce(p_titulaire_constate, '')), ''), v.nom_titulaire)));
  insert into public.dossier_messages (dossier_id, auteur, contenu)
  values (p_dossier, 'systeme', format('Nous avons bien reçu votre premier versement de %s €.', gmb_prive.euros(p_montant_recu)));
  return jsonb_build_object('statut', 'recu', 'montant_recu', p_montant_recu);
end $$;

-- Projet de crédit d'un non-client (ONB-C)
create or replace function public.gmb_dossier_credit_projet(p_dossier uuid, p_montant numeric, p_duree int, p_objet text default 'autre',
                                                            p_revenus numeric default null, p_charges numeric default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare s jsonb;
begin
  if not gmb_prive.dossier_du_demandeur(p_dossier) or (select type from public.dossiers where id = p_dossier) <> 'credit' then
    raise exception 'Dossier de crédit introuvable.' using errcode = '42501';
  end if;
  s := public.gmb_simuler_credit(p_montant, p_duree, p_objet);
  if not (s ->> 'disponible')::boolean then
    raise exception '%', s ->> 'message' using errcode = '22023';
  end if;
  insert into public.dossier_credit (dossier_id, objet, montant, duree_mois, revenus_mensuels, charges_mensuelles,
                                     taux_debiteur, taeg, mensualite, cout_total, montant_total_du)
  values (p_dossier, coalesce(p_objet, 'autre'), p_montant, p_duree, p_revenus, p_charges,
          (s ->> 'taux_debiteur')::numeric, (s ->> 'taeg')::numeric, (s ->> 'mensualite')::numeric,
          (s ->> 'cout_total')::numeric, (s ->> 'montant_total_du')::numeric)
  on conflict (dossier_id) do update set objet = excluded.objet, montant = excluded.montant, duree_mois = excluded.duree_mois,
     revenus_mensuels = excluded.revenus_mensuels, charges_mensuelles = excluded.charges_mensuelles,
     taux_debiteur = excluded.taux_debiteur, taeg = excluded.taeg, mensualite = excluded.mensualite,
     cout_total = excluded.cout_total, montant_total_du = excluded.montant_total_du;
  return s;
end $$;

-- Dépôt du dossier (ONB-11) : pièces, consentements et premier versement vérifiés
create or replace function public.gmb_dossier_deposer(p_dossier uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare d record; v_manquantes int;
begin
  if not gmb_prive.dossier_du_demandeur(p_dossier) then
    raise exception 'Dossier introuvable.' using errcode = '42501';
  end if;
  select * into d from public.dossiers where id = p_dossier for update;
  if d.etat <> 'brouillon' then
    raise exception 'Ce dossier est déjà déposé.' using errcode = '55000';
  end if;
  select count(*) into v_manquantes from public.dossier_pieces where dossier_id = p_dossier and statut in ('attendue', 'refusee');
  if v_manquantes > 0 then
    raise exception 'Il manque % pièce(s) à votre dossier.', v_manquantes using errcode = '55000';
  end if;
  if not exists (select 1 from public.consentements where auth_user_id = auth.uid() and type = 'cgu' and accorde)
     or not exists (select 1 from public.consentements where auth_user_id = auth.uid() and type = 'confidentialite' and accorde) then
    raise exception 'Merci d''accepter les conditions générales et la politique de confidentialité.' using errcode = '55000';
  end if;
  if d.type = 'ouverture' and d.segment in ('pro', 'business') and not exists (select 1 from public.dossier_entreprises where dossier_id = p_dossier) then
    raise exception 'Renseignez les informations de votre entreprise.' using errcode = '55000';
  end if;
  if d.type = 'ouverture' and d.segment = 'jeunes' and not exists (select 1 from public.dossier_jeunes where dossier_id = p_dossier) then
    raise exception 'Renseignez les informations de votre enfant.' using errcode = '55000';
  end if;
  if d.type = 'ouverture' and not exists (select 1 from public.premiers_versements where dossier_id = p_dossier) then
    raise exception 'Le premier versement est nécessaire pour déposer votre dossier.' using errcode = '55000';
  end if;
  if d.type = 'credit' and not exists (select 1 from public.dossier_credit where dossier_id = p_dossier and consentement_ficp) then
    raise exception 'Votre accord pour la consultation du FICP est nécessaire.' using errcode = '55000';
  end if;
  update public.dossiers
     set etat = case when d.type = 'credit' then 'demande_deposee' else 'depose' end,
         depose_le = now(), sla_echeance = gmb_prive.ajouter_jours_ouvres(now(), 2), etape_tunnel = 11
   where id = p_dossier;
  return jsonb_build_object('reference', d.reference, 'etat', case when d.type = 'credit' then 'demande_deposee' else 'depose' end);
end $$;

-- Remise de l'identifiant bancaire (DOS-07). Il s'affiche à la première consultation,
-- puis reste masqué (« •••• 1530 ») : le titulaire le fait réafficher en confirmant son
-- mot de passe sur le site. Chaque affichage est inscrit au journal d'audit, sans
-- l'identifiant lui-même.
drop function if exists public.gmb_dossier_identifiant(uuid);
create or replace function public.gmb_dossier_identifiant(p_dossier uuid, p_reveler boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_id text; v_vu timestamptz; v_active boolean;
begin
  if not gmb_prive.dossier_du_demandeur(p_dossier) then
    raise exception 'Dossier introuvable.' using errcode = '42501';
  end if;
  select c.identifiant, d.identifiant_vu_le, c.auth_user_id is not null into v_id, v_vu, v_active
    from public.dossiers d join public.clients c on c.dossier_origine_id = d.id
   where d.id = p_dossier and d.etat in ('compte_ouvert', 'archive');
  if v_id is null then
    raise exception 'Votre identifiant sera disponible dès l''ouverture de votre compte.' using errcode = '55000';
  end if;
  if v_vu is null or coalesce(p_reveler, false) then
    update public.dossiers set identifiant_vu_le = coalesce(identifiant_vu_le, now()) where id = p_dossier;
    insert into public.journal_audit (acteur_id, acteur_type, action, objet_type, objet_id, motif)
    values (auth.uid(), 'client', 'IDENTIFIANT_AFFICHE', 'dossier', p_dossier::text,
            case when v_vu is null then 'Première consultation' else 'Nouvel affichage après confirmation du mot de passe' end);
    return jsonb_build_object('identifiant', v_id, 'masque', false, 'acces_active', v_active);
  end if;
  return jsonb_build_object('identifiant', '•••• ' || right(v_id, 4), 'masque', true, 'acces_active', v_active);
end $$;

-- Acceptation d'une offre de crédit (DOS-06, PAR-13) : délai de rétractation de
-- 14 jours ; versement des fonds possible au plus tôt le 8e jour
create or replace function public.gmb_credit_accepter(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
begin
  if gmb_prive.dossier_du_demandeur(p_id) then
    if (select etat from public.dossiers where id = p_id) <> 'offre_emise' then
      raise exception 'Aucune offre à accepter.' using errcode = '55000';
    end if;
    update public.dossier_credit
       set acceptee_le = now(), retractation_fin = now() + interval '14 days', deblocage_possible_le = (current_date + 7)::timestamptz
     where dossier_id = p_id;
    update public.dossiers set etat = 'delai_legal' where id = p_id;
  elsif exists (select 1 from public.demandes where id = p_id and client_id = gmb_prive.client_courant()) then
    if (select etat from public.demandes where id = p_id) <> 'offre_emise' then
      raise exception 'Aucune offre à accepter.' using errcode = '55000';
    end if;
    update public.demandes
       set etat = 'delai_legal', acceptee_le = now(), retractation_fin = now() + interval '14 days',
           deblocage_possible_le = (current_date + 7)::timestamptz
     where id = p_id;
  else
    raise exception 'Demande introuvable.' using errcode = '42501';
  end if;
  return jsonb_build_object('etat', 'delai_legal', 'retractation_fin', now() + interval '14 days',
                            'deblocage_possible_le', current_date + 7);
end $$;

-- Rétractation (« Me rétracter », DOS-06, PAR-13)
create or replace function public.gmb_credit_retracter(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_etat text; v_fin timestamptz;
begin
  if gmb_prive.dossier_du_demandeur(p_id) then
    select d.etat, c.retractation_fin into v_etat, v_fin from public.dossiers d left join public.dossier_credit c on c.dossier_id = d.id where d.id = p_id;
    if v_etat not in ('offre_emise', 'delai_legal', 'acceptee') or (v_fin is not null and now() > v_fin) then
      raise exception 'Le délai de rétractation est dépassé ou la demande est close.' using errcode = '55000';
    end if;
    update public.dossiers set etat = 'renonciation' where id = p_id;
  elsif exists (select 1 from public.demandes where id = p_id and client_id = gmb_prive.client_courant()) then
    select etat, retractation_fin into v_etat, v_fin from public.demandes where id = p_id;
    if v_etat not in ('demande_deposee', 'analyse', 'offre_emise', 'delai_legal', 'acceptee') or (v_fin is not null and now() > v_fin) then
      raise exception 'Le délai de rétractation est dépassé ou la demande est close.' using errcode = '55000';
    end if;
    update public.demandes set etat = 'renonciation' where id = p_id;
  else
    raise exception 'Demande introuvable.' using errcode = '42501';
  end if;
  return jsonb_build_object('etat', 'renonciation');
end $$;


-- ---------- 11.4 Espace client : paiements ----------------------------------

-- Vérification du nom du bénéficiaire (VoP, règlement (UE) 2024/886)
create or replace function public.gmb_vop_verifier(p_nom text, p_iban text)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_saisie text := upper(replace(coalesce(p_iban, ''), ' ', '')); v_officiel text; a text; b text;
begin
  if gmb_prive.client_courant() is null then
    raise exception 'Connexion requise.' using errcode = '42501';
  end if;
  if v_saisie ~ '^[0-9]{11}$' then
    -- Compte GerMoonBank : vérification réelle du titulaire
    if not gmb_prive.luhn_valide(v_saisie) then
      return jsonb_build_object('resultat', 'iban_invalide', 'message', 'Ce numéro de compte GerMoonBank n''est pas valide. Vérifiez-le.');
    end if;
    select coalesce(e.raison_sociale, p.prenoms || ' ' || coalesce(nullif(btrim(p.nom_usage), ''), p.nom_naissance)) into v_officiel
      from public.comptes c
      left join public.clients cl on cl.id = c.client_id
      left join public.personnes p on p.id = cl.personne_id
      left join public.entreprises e on e.id = c.entreprise_id
     where c.numero = v_saisie and c.statut = 'actif';
    if v_officiel is null then
      return jsonb_build_object('resultat', 'iban_invalide', 'message', 'Aucun compte GerMoonBank actif ne porte ce numéro.');
    end if;
  else
    if not gmb_prive.iban_valide(v_saisie) then
      return jsonb_build_object('resultat', 'iban_invalide', 'message', 'Cet IBAN n''est pas valide. Vérifiez-le.');
    end if;
    select coalesce(e.raison_sociale, p.prenoms || ' ' || coalesce(nullif(btrim(p.nom_usage), ''), p.nom_naissance)) into v_officiel
      from public.comptes c
      left join public.clients cl on cl.id = c.client_id
      left join public.personnes p on p.id = cl.personne_id
      left join public.entreprises e on e.id = c.entreprise_id
     where c.iban = v_saisie and c.statut = 'actif';
    if v_officiel is null then
      return jsonb_build_object('resultat', 'impossible', 'message', 'Le nom ne peut pas être vérifié pour ce compte extérieur à GerMoonBank : contrôlez soigneusement le nom et l''IBAN avant d''envoyer.');
    end if;
  end if;
  a := gmb_prive.normaliser_nom(p_nom);
  b := gmb_prive.normaliser_nom(v_officiel);
  if a = b then
    return jsonb_build_object('resultat', 'correspondance', 'nom', v_officiel);
  end if;
  if a <> '' and (position(a in b) > 0 or position(b in a) > 0 or exists (
       select 1 from unnest(string_to_array(replace(a, '-', ' '), ' ')) x
        where length(x) > 2 and x = any (string_to_array(replace(b, '-', ' '), ' ')))) then
    return jsonb_build_object('resultat', 'partielle', 'nom', v_officiel, 'message', format('Le compte est enregistré au nom de %s.', v_officiel));
  end if;
  return jsonb_build_object('resultat', 'aucune', 'message', 'Le nom saisi ne correspond pas au titulaire de ce compte.');
end $$;

-- Ajout d'un bénéficiaire : plafond temporaire de 1 000 € pendant 72 heures (PAR-05)
create or replace function public.gmb_beneficiaire_ajouter(p_nom text, p_iban text, p_utiliser_nom_verifie boolean default false, p_entreprise uuid default null)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare r jsonb; v_id uuid; v_client uuid := gmb_prive.client_courant(); v_plafond numeric; v_heures int; v_resultat text;
  v_saisie text := upper(replace(coalesce(p_iban, ''), ' ', '')); v_interne boolean;
begin
  if v_client is null then
    raise exception 'Connexion requise.' using errcode = '42501';
  end if;
  if p_entreprise is not null and coalesce(gmb_prive.role_entreprise(p_entreprise), '') not in ('administrateur', 'responsable_financier', 'comptable') then
    raise exception 'Votre rôle ne permet pas d''ajouter un bénéficiaire.' using errcode = '42501';
  end if;
  r := public.gmb_vop_verifier(p_nom, v_saisie);
  if r ->> 'resultat' = 'iban_invalide' then
    raise exception '%', r ->> 'message' using errcode = '22023';
  end if;
  v_interne := v_saisie ~ '^[0-9]{11}$';
  v_resultat := case when p_utiliser_nom_verifie and r ? 'nom' then 'correspondance' else r ->> 'resultat' end;
  select coalesce(max(valeur) filter (where cle = 'nouveau_beneficiaire_plafond'), 1000),
         coalesce(max(valeur) filter (where cle = 'nouveau_beneficiaire_heures'), 72)::int
    into v_plafond, v_heures from public.parametres_securite;
  insert into public.beneficiaires (client_id, entreprise_id, nom, nom_verifie, iban, numero_compte, vop_resultat, plafond_temporaire, plafond_temporaire_jusqu)
  values (case when p_entreprise is null then v_client end, p_entreprise,
          case when p_utiliser_nom_verifie and r ? 'nom' then r ->> 'nom' else p_nom end, r ->> 'nom',
          case when v_interne then null else v_saisie end, case when v_interne then v_saisie end,
          v_resultat, v_plafond, now() + make_interval(hours => v_heures))
  returning id into v_id;
  perform gmb_prive.notifier(v_client, null, 'Nouveau bénéficiaire ajouté',
    format('%s a été ajouté à vos bénéficiaires. Si ce n''était pas vous, contactez-nous immédiatement.', coalesce(r ->> 'nom', p_nom)),
    null, 'push', 'MSG-BENEF-01');
  return jsonb_build_object('beneficiaire', v_id) || r;
end $$;

-- Exécution d'un virement validé (débit, et crédit si le compte destinataire est chez GMB)
create or replace function gmb_prive.executer_virement(p_virement uuid)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v record; b record; c record; v_dest uuid; v_emetteur text;
begin
  select * into v from public.virements where id = p_virement for update;
  select * into b from public.beneficiaires where id = v.beneficiaire_id;
  select * into c from public.comptes where id = v.compte_id for update;
  if c.solde < v.montant then
    update public.virements set statut = 'rejete', motif_rejet = 'Solde insuffisant' where id = p_virement;
    return jsonb_build_object('statut', 'rejete', 'message', format('Votre solde ne permet pas ce virement. Il vous manque %s €.', gmb_prive.euros(v.montant - c.solde)));
  end if;
  if b.numero_compte is not null then
    select id into v_dest from public.comptes where numero = b.numero_compte and statut = 'actif';
  elsif b.iban is not null then
    select id into v_dest from public.comptes where iban = b.iban and statut = 'actif';
  end if;
  insert into public.operations (compte_id, type, libelle, contrepartie_nom, contrepartie_iban, montant, categorie_code, virement_id, motif)
  values (v.compte_id, 'virement_emis', 'Virement à ' || coalesce(b.nom_verifie, b.nom), coalesce(b.nom_verifie, b.nom),
          coalesce(b.iban, b.numero_compte), -v.montant, 'transferts', v.id, v.motif);
  if v_dest is not null then
    -- Bénéficiaire client de GerMoonBank : le virement est exécuté immédiatement
    select coalesce(e.raison_sociale, p.prenoms || ' ' || coalesce(nullif(btrim(p.nom_usage), ''), p.nom_naissance)) into v_emetteur
      from public.comptes co
      left join public.clients cl on cl.id = co.client_id
      left join public.personnes p on p.id = cl.personne_id
      left join public.entreprises e on e.id = co.entreprise_id
     where co.id = v.compte_id;
    insert into public.operations (compte_id, type, libelle, contrepartie_nom, contrepartie_iban, montant, categorie_code, virement_id, motif)
    values (v_dest, 'virement_recu', 'Virement de ' || coalesce(v_emetteur, 'GerMoonBank'), v_emetteur, coalesce(c.iban, c.numero), v.montant, 'transferts', v.id, v.motif);
    update public.virements set statut = 'execute', execute_le = now() where id = p_virement;
    return jsonb_build_object('statut', 'execute');
  end if;
  -- Compte d'une autre banque : les fonds sont débités et le virement attend
  -- son exécution par la trésorerie (gmb_bo_virement_executer)
  update public.virements set statut = 'a_executer' where id = p_virement;
  return jsonb_build_object('statut', 'a_executer',
    'message', 'Votre compte est débité. Le virement est transmis à la banque du bénéficiaire par notre trésorerie.');
end $$;

-- Trésorerie : exécution d'un virement vers une autre banque (ADM-16)
create or replace function public.gmb_bo_virement_executer(p_virement uuid, p_reference text)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v record; v_client uuid;
begin
  if not gmb_prive.bo_decision('ADM-16') then
    raise exception 'Droits insuffisants.' using errcode = '42501';
  end if;
  select * into v from public.virements where id = p_virement for update;
  if not found or v.statut <> 'a_executer' then
    raise exception 'Ce virement n''est pas en attente d''exécution.' using errcode = '55000';
  end if;
  if coalesce(trim(p_reference), '') = '' then
    raise exception 'Indiquez la référence de l''ordre passé à la banque.' using errcode = '22023';
  end if;
  update public.virements set statut = 'execute', execute_le = now(), reference_execution = trim(p_reference) where id = p_virement;
  select client_id into v_client from public.comptes where id = v.compte_id;
  if v_client is not null then
    perform gmb_prive.notifier(v_client, null, 'Virement envoyé',
      format('Votre virement de %s a été transmis à la banque du bénéficiaire.', gmb_prive.euros(v.montant)), null, 'push');
  end if;
  return jsonb_build_object('statut', 'execute');
end $$;

-- Trésorerie : virement vers une autre banque impossible à exécuter, fonds rendus (ADM-16)
create or replace function public.gmb_bo_virement_rejeter(p_virement uuid, p_motif text)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v record; v_client uuid;
begin
  if not gmb_prive.bo_decision('ADM-16') then
    raise exception 'Droits insuffisants.' using errcode = '42501';
  end if;
  select * into v from public.virements where id = p_virement for update;
  if not found or v.statut <> 'a_executer' then
    raise exception 'Ce virement n''est pas en attente d''exécution.' using errcode = '55000';
  end if;
  if coalesce(trim(p_motif), '') = '' then
    raise exception 'Indiquez le motif du rejet.' using errcode = '22023';
  end if;
  insert into public.operations (compte_id, type, libelle, montant, categorie_code, virement_id, motif)
  values (v.compte_id, 'remboursement', 'Virement non exécuté : fonds restitués', v.montant, 'transferts', v.id, trim(p_motif));
  update public.virements set statut = 'rejete', motif_rejet = trim(p_motif) where id = p_virement;
  select client_id into v_client from public.comptes where id = v.compte_id;
  if v_client is not null then
    perform gmb_prive.notifier(v_client, null, 'Virement non exécuté',
      format('Votre virement de %s n''a pas pu être exécuté : %s. La somme vous est restituée.', gmb_prive.euros(v.montant), trim(p_motif)), null, 'push');
  end if;
  return jsonb_build_object('statut', 'rejete');
end $$;

-- Trésorerie : fonds reçus d'une autre banque pour un client (ADM-16)
-- État d'un service affiché sur la page publique (ADM-01)
create or replace function public.gmb_bo_service_etat(p_service text, p_etat text, p_message text default null)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
begin
  if not gmb_prive.bo_decision('ADM-01') then
    raise exception 'Droits insuffisants.' using errcode = '42501';
  end if;
  update public.statut_services set etat = p_etat, message = nullif(trim(coalesce(p_message, '')), ''), maj_le = now() where service = p_service;
  if not found then
    raise exception 'Service inconnu.' using errcode = '22023';
  end if;
  return jsonb_build_object('service', p_service, 'etat', p_etat);
end $$;

-- Préparation d'un virement (PAR-05, BIZ-04)
create or replace function public.gmb_virement_creer(p_compte uuid, p_beneficiaire uuid, p_montant numeric, p_motif text default null,
                                                     p_type text default 'instantane', p_date date default current_date,
                                                     p_frequence text default null, p_vop_choix text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare c record; b record; v_deja numeric; v_id uuid; v_regle record; v_statut text := 'a_valider';
        v_client uuid := gmb_prive.client_courant();
begin
  if v_client is null or not gmb_prive.compte_accessible(p_compte) then
    raise exception 'Compte introuvable.' using errcode = '42501';
  end if;
  select * into c from public.comptes where id = p_compte;
  if c.type not in ('courant', 'pro', 'business') or c.statut <> 'actif' then
    raise exception 'Les virements partent d''un compte courant actif.' using errcode = '22023';
  end if;
  select * into b from public.beneficiaires
   where id = p_beneficiaire and (client_id = v_client or (entreprise_id is not null and entreprise_id = c.entreprise_id));
  if not found then
    raise exception 'Bénéficiaire introuvable.' using errcode = '42501';
  end if;
  if p_montant is null or p_montant <= 0 then
    raise exception 'Le montant doit être positif.' using errcode = '22023';
  end if;
  if b.vop_resultat in ('partielle', 'aucune', 'impossible') and coalesce(p_vop_choix, '') <> 'continuer' then
    raise exception 'Le nom du bénéficiaire n''a pas été confirmé. Confirmez pour continuer malgré tout.' using errcode = '22023';
  end if;
  if now() < b.plafond_temporaire_jusqu then
    select coalesce(sum(montant), 0) into v_deja from public.virements
     where beneficiaire_id = b.id and statut not in ('rejete', 'annule');
    if v_deja + p_montant > b.plafond_temporaire then
      raise exception 'Nouveau bénéficiaire : plafond de % € pendant 72 heures, par sécurité.', gmb_prive.euros(b.plafond_temporaire)
        using errcode = '22023';
    end if;
  end if;
  if c.entreprise_id is not null then
    select * into v_regle from public.regles_approbation
     where entreprise_id = c.entreprise_id and type_operation = 'virement' and actif and p_montant > seuil
     order by seuil desc limit 1;
    if found then v_statut := 'en_approbation'; end if;
  end if;
  insert into public.virements (compte_id, beneficiaire_id, montant, motif, type, date_execution, frequence, statut,
                                vop_resultat, vop_choix, cree_par)
  values (p_compte, b.id, p_montant, p_motif, coalesce(p_type, 'instantane'), coalesce(p_date, current_date), p_frequence, v_statut,
          b.vop_resultat, p_vop_choix, auth.uid())
  returning id into v_id;
  if v_statut = 'en_approbation' then
    insert into public.demandes_approbation (entreprise_id, regle_id, type, objet_id, libelle, montant, demandeur_id)
    values (c.entreprise_id, v_regle.id, 'virement', v_id, 'Virement · ' || coalesce(b.nom_verifie, b.nom), p_montant, v_client);
  end if;
  return jsonb_build_object('virement', v_id, 'statut', v_statut, 'beneficiaire', coalesce(b.nom_verifie, b.nom), 'montant', p_montant);
end $$;

-- Validation par authentification forte du client
create or replace function public.gmb_virement_valider(p_virement uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v record;
begin
  select * into v from public.virements where id = p_virement;
  if not found or not gmb_prive.compte_accessible(v.compte_id) then
    raise exception 'Virement introuvable.' using errcode = '42501';
  end if;
  if v.statut <> 'a_valider' then
    raise exception 'Ce virement n''est pas à valider.' using errcode = '55000';
  end if;
  update public.virements set statut = 'valide', sca_le = now() where id = p_virement;
  if v.type in ('instantane', 'standard') and v.date_execution <= current_date then
    return gmb_prive.executer_virement(p_virement);
  end if;
  return jsonb_build_object('statut', 'valide', 'date_execution', v.date_execution);
end $$;

create or replace function public.gmb_virement_annuler(p_virement uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v record;
begin
  select * into v from public.virements where id = p_virement;
  if not found or not gmb_prive.compte_accessible(v.compte_id) then
    raise exception 'Virement introuvable.' using errcode = '42501';
  end if;
  if v.statut not in ('a_valider', 'valide', 'en_approbation') or (v.statut = 'valide' and v.date_execution <= current_date) then
    raise exception 'Ce virement ne peut plus être annulé.' using errcode = '55000';
  end if;
  update public.virements set statut = 'annule' where id = p_virement;
  update public.demandes_approbation set statut = 'refusee' where objet_id = p_virement and statut = 'en_attente';
  return jsonb_build_object('statut', 'annule');
end $$;


-- ---------- 11.5 Espace client : cartes, coffres, opérations ----------------

create or replace function public.gmb_carte_regler(p_carte uuid, p_reglage text, p_valeur boolean)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
begin
  if not gmb_prive.carte_accessible(p_carte) then
    raise exception 'Carte introuvable.' using errcode = '42501';
  end if;
  case p_reglage
    when 'gelee' then
      update public.cartes set statut = case when p_valeur then 'gelee' else 'active' end
       where id = p_carte and statut in ('active', 'gelee');
    when 'sans_contact' then update public.cartes set sans_contact = p_valeur where id = p_carte;
    when 'paiement_en_ligne' then update public.cartes set paiement_en_ligne = p_valeur where id = p_carte;
    when 'retraits' then update public.cartes set retraits = p_valeur where id = p_carte;
    when 'etranger' then update public.cartes set etranger = p_valeur where id = p_carte;
    else raise exception 'Réglage inconnu.' using errcode = '22023';
  end case;
  return (select to_jsonb(k) - 'jeton_processeur' from public.cartes k where k.id = p_carte);
end $$;

create or replace function public.gmb_carte_plafonds(p_carte uuid, p_paiement numeric, p_retrait numeric)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
begin
  if not gmb_prive.carte_accessible(p_carte) then
    raise exception 'Carte introuvable.' using errcode = '42501';
  end if;
  if p_paiement not between 50 and 10000 or p_retrait not between 20 and 3000 then
    raise exception 'Plafonds possibles : paiements de 50 € à 10 000 € sur 30 jours, retraits de 20 € à 3 000 € sur 7 jours.' using errcode = '22023';
  end if;
  update public.cartes set plafond_paiement_30j = p_paiement, plafond_retrait_7j = p_retrait where id = p_carte;
  return (select to_jsonb(k) - 'jeton_processeur' from public.cartes k where k.id = p_carte);
end $$;

-- Opposition définitive et commande d'une nouvelle carte (PAR-04)
create or replace function public.gmb_carte_opposition(p_carte uuid, p_motif text)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare k record;
begin
  if not gmb_prive.carte_accessible(p_carte) then
    raise exception 'Carte introuvable.' using errcode = '42501';
  end if;
  select * into k from public.cartes where id = p_carte for update;
  if k.statut = 'opposition' then
    raise exception 'Cette carte est déjà en opposition.' using errcode = '55000';
  end if;
  update public.cartes set statut = 'opposition', motif_opposition = p_motif where id = p_carte;
  perform gmb_prive.notifier(k.titulaire_client_id, null, 'Opposition enregistrée',
    format('Votre carte •••• %s est définitivement bloquée.', k.derniers_chiffres), null, 'push');
  return jsonb_build_object('statut', 'opposition');
end $$;

-- Nouveau coffre (PAR-06) dans la limite de la formule
create or replace function public.gmb_coffre_creer(p_nom text, p_objectif numeric default null, p_date date default null,
                                                   p_arrondi int default 0)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_client uuid := gmb_prive.client_courant(); v_max int; v_parent uuid; v_compte uuid; v_id uuid;
begin
  if v_client is null then
    raise exception 'Connexion requise.' using errcode = '42501';
  end if;
  select f.coffres_max into v_max from public.clients c join public.formules f on f.code = c.formule_code where c.id = v_client;
  if v_max is not null and (select count(*) from public.coffres where client_id = v_client and statut <> 'clos') >= v_max then
    raise exception 'Votre formule permet % coffres. Passez à une formule supérieure pour en créer davantage.', v_max using errcode = '22023';
  end if;
  select id into v_parent from public.comptes
   where client_id = v_client and type in ('courant', 'jeune') and statut = 'actif' order by ouvert_le limit 1;
  insert into public.comptes (client_id, type, libelle, compte_parent_id)
  values (v_client, 'coffre', 'Coffre « ' || p_nom || ' »', v_parent) returning id into v_compte;
  insert into public.coffres (client_id, compte_id, nom, objectif, date_objectif, arrondi_multiplicateur, demarre_le)
  values (v_client, v_compte, p_nom, p_objectif, p_date, coalesce(p_arrondi, 0), current_date) returning id into v_id;
  return jsonb_build_object('coffre', v_id, 'compte', v_compte);
end $$;

-- Alimenter (montant positif) ou retirer (montant négatif) un coffre
create or replace function public.gmb_coffre_mouvement(p_coffre uuid, p_montant numeric)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare k record; v_parent record; v_coffre record;
begin
  select * into k from public.coffres where id = p_coffre and client_id = gmb_prive.client_courant();
  if not found then
    raise exception 'Coffre introuvable.' using errcode = '42501';
  end if;
  select * into v_coffre from public.comptes where id = k.compte_id for update;
  select * into v_parent from public.comptes where id = v_coffre.compte_parent_id for update;
  if p_montant is null or p_montant = 0 then
    raise exception 'Indiquez un montant.' using errcode = '22023';
  end if;
  if p_montant > 0 and v_parent.solde < p_montant then
    raise exception 'Votre solde ne permet pas ce versement. Il vous manque % €.', gmb_prive.euros(p_montant - v_parent.solde) using errcode = '22023';
  end if;
  if p_montant < 0 and v_coffre.solde < -p_montant then
    raise exception 'Le coffre contient seulement % €.', gmb_prive.euros(v_coffre.solde) using errcode = '22023';
  end if;
  insert into public.operations (compte_id, type, libelle, montant, categorie_code) values
    (v_parent.id, 'interne', case when p_montant > 0 then 'Vers « ' || k.nom || ' »' else 'Depuis « ' || k.nom || ' »' end, -p_montant, 'epargne'),
    (v_coffre.id, 'interne', case when p_montant > 0 then 'Versement' else 'Retrait' end, p_montant, 'epargne');
  return jsonb_build_object('solde_coffre', (select solde from public.comptes where id = k.compte_id));
end $$;

-- Catégorie, motif, pointage, justificatif et budget d'une opération (PAR-03)
create or replace function public.gmb_operation_annoter(p_operation uuid, p_categorie text default null, p_motif text default null,
                                                        p_pointee boolean default null, p_justificatif text default null,
                                                        p_budget uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r jsonb;
begin
  update public.operations o
     set categorie_code = coalesce(p_categorie, categorie_code), motif = coalesce(p_motif, motif),
         pointee = coalesce(p_pointee, pointee), justificatif_chemin = coalesce(p_justificatif, justificatif_chemin),
         budget_id = coalesce(p_budget, budget_id)
   where o.id = p_operation and gmb_prive.compte_accessible(o.compte_id)
  returning to_jsonb(o) into r;
  if r is null then
    raise exception 'Opération introuvable.' using errcode = '42501';
  end if;
  return r;
end $$;

-- « Je ne reconnais pas cette opération » (PAR-03) : remboursement au plus tard
-- à la fin du premier jour ouvrable suivant, délai de contestation de 13 mois
create or replace function public.gmb_operation_contester(p_operation uuid, p_motif text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o record; v_id uuid; v_client uuid := gmb_prive.client_courant();
begin
  select * into o from public.operations where id = p_operation;
  if not found or not gmb_prive.compte_accessible(o.compte_id) then
    raise exception 'Opération introuvable.' using errcode = '42501';
  end if;
  if o.montant >= 0 or o.date_operation < now() - interval '13 months' then
    raise exception 'Cette opération ne peut pas être contestée.' using errcode = '22023';
  end if;
  insert into public.contestations (client_id, operation_id, motif, montant, rembourser_avant)
  values (v_client, p_operation, p_motif, -o.montant, gmb_prive.ajouter_jours_ouvres(date_trunc('day', now()), 2) - interval '1 second')
  returning id into v_id;
  insert into public.alertes_fraude (client_id, operation_id, type, score, details)
  values (v_client, p_operation, 'contestation', 60, jsonb_build_object('motif', p_motif));
  return jsonb_build_object('contestation', v_id, 'statut', 'ouverte');
end $$;

-- Conversion de MoonPoints en euros (100 points = 1 €)
create or replace function public.gmb_moonpoints_convertir(p_points int)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_client uuid := gmb_prive.client_courant(); v_solde int; v_compte uuid;
begin
  if v_client is null then
    raise exception 'Connexion requise.' using errcode = '42501';
  end if;
  select coalesce(sum(points), 0) into v_solde from public.moonpoints
   where client_id = v_client and (expire_le is null or expire_le >= current_date);
  if p_points is null or p_points < 100 or p_points > v_solde then
    raise exception 'Conversion possible à partir de 100 MoonPoints, dans la limite de votre solde (% points).', v_solde using errcode = '22023';
  end if;
  select id into v_compte from public.comptes where client_id = v_client and type in ('courant', 'jeune') and statut = 'actif' order by ouvert_le limit 1;
  insert into public.moonpoints (client_id, points, motif) values (v_client, -p_points, 'Conversion en euros');
  insert into public.operations (compte_id, type, libelle, montant, categorie_code)
  values (v_compte, 'moonpoints', 'Conversion de ' || p_points || ' MoonPoints', round(p_points / 100.0, 2), 'epargne');
  return jsonb_build_object('points', p_points, 'euros', round(p_points / 100.0, 2), 'solde_points', v_solde - p_points);
end $$;

-- Demande de prêt personnel d'un client, suivie dans « Mes demandes » (PAR-12, PAR-13)
create or replace function public.gmb_demande_credit(p_montant numeric, p_duree int, p_objet text default 'autre')
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_client uuid := gmb_prive.client_courant(); s jsonb; v_id uuid; v_ref text;
begin
  if v_client is null then
    raise exception 'Connexion requise.' using errcode = '42501';
  end if;
  s := public.gmb_simuler_credit(p_montant, p_duree, p_objet);
  if not (s ->> 'disponible')::boolean then
    raise exception '%', s ->> 'message' using errcode = '22023';
  end if;
  insert into public.demandes (client_id, reference, type, montant, duree_mois, objet, taux_debiteur, taeg, mensualite,
                               cout_total, montant_total_du, donnees)
  values (v_client, gmb_prive.reference('CRE'), 'pret_personnel', p_montant, p_duree, p_objet, (s ->> 'taux_debiteur')::numeric,
          (s ->> 'taeg')::numeric, (s ->> 'mensualite')::numeric, (s ->> 'cout_total')::numeric, (s ->> 'montant_total_du')::numeric, s)
  returning id, reference into v_id, v_ref;
  insert into public.demande_evenements (demande_id, etat_apres, libelle_client) values (v_id, 'demande_deposee', 'Demande de prêt déposée');
  return jsonb_build_object('demande', v_id, 'reference', v_ref) || s;
end $$;

-- GerMoonBank · installation de la base, partie 4 sur 8
-- Exécutez les parties dans l'ordre, chacune dans une requête vide du SQL Editor.
-- Contenu : 03_fonctions
-- Réclamation (PAR-15) : accusé sous 10 jours ouvrables, réponse sous 15 jours
-- ouvrables (paiements) ou 2 mois (autres sujets)
create or replace function public.gmb_reclamation_creer(p_objet text, p_description text, p_categorie text default 'autre')
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_client uuid := gmb_prive.client_courant(); r record;
begin
  if v_client is null then
    raise exception 'Connexion requise.' using errcode = '42501';
  end if;
  insert into public.reclamations (client_id, reference, categorie, objet, description, accuse_avant, reponse_avant)
  values (v_client, gmb_prive.reference('REC'), coalesce(p_categorie, 'autre'), p_objet, p_description,
          gmb_prive.ajouter_jours_ouvres(now(), 10),
          case when p_categorie in ('paiement', 'carte') then gmb_prive.ajouter_jours_ouvres(now(), 15) else now() + interval '2 months' end)
  returning reference, accuse_avant, reponse_avant into r;
  return jsonb_build_object('reference', r.reference, 'accuse_avant', r.accuse_avant, 'reponse_avant', r.reponse_avant);
end $$;

-- Préférences : thème clair, sombre ou système ; langue ; notifications (PAR-16)
create or replace function public.gmb_preferences(p_theme text default null, p_langue text default null, p_preferences jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r jsonb;
begin
  update public.clients c
     set theme = coalesce(p_theme, theme), langue = coalesce(p_langue, langue),
         preferences = preferences || coalesce(p_preferences, '{}'::jsonb)
   where c.id = gmb_prive.client_courant()
  returning jsonb_build_object('theme', c.theme, 'langue', c.langue, 'preferences', c.preferences) into r;
  if r is null then
    raise exception 'Connexion requise.' using errcode = '42501';
  end if;
  return r;
end $$;

create or replace function public.gmb_notification_lue(p_notification uuid default null)
returns int language plpgsql volatile security definer set search_path = '' as $$
declare n int;
begin
  update public.notifications set lu_le = now()
   where lu_le is null and (p_notification is null or id = p_notification)
     and (destinataire_auth = auth.uid() or client_id = gmb_prive.client_courant());
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.gmb_appareil_revoquer(p_appareil uuid)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  update public.appareils set revoque_le = now()
   where id = p_appareil and client_id = gmb_prive.client_courant() and revoque_le is null;
  if not found then
    raise exception 'Appareil introuvable.' using errcode = '42501';
  end if;
end $$;


-- ---------- 11.6 Espace Business et Pro --------------------------------------

-- Décision d'un valideur (BIZ-05) : ordre des rôles, interdiction de valider
-- sa propre demande, exécution du virement après la dernière validation
create or replace function public.gmb_approbation_decider(p_demande uuid, p_decision text, p_commentaire text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare d record; r record; v_client uuid := gmb_prive.client_courant(); v_role text; v_nb int; v_attendu text;
begin
  select * into d from public.demandes_approbation where id = p_demande for update;
  if not found or not gmb_prive.membre_entreprise(d.entreprise_id) then
    raise exception 'Demande introuvable.' using errcode = '42501';
  end if;
  if d.statut <> 'en_attente' then
    raise exception 'Cette demande a déjà été traitée.' using errcode = '55000';
  end if;
  if d.demandeur_id = v_client then
    raise exception 'Vous ne pouvez pas valider votre propre demande.' using errcode = '42501';
  end if;
  if p_decision not in ('validee', 'refusee') then
    raise exception 'Décision inconnue.' using errcode = '22023';
  end if;
  v_role := gmb_prive.role_entreprise(d.entreprise_id);
  select * into r from public.regles_approbation where id = d.regle_id;
  if r.id is not null and not (v_role = any (r.roles_valideurs)) then
    raise exception 'Votre rôle ne permet pas de valider cette demande.' using errcode = '42501';
  end if;
  select count(*) into v_nb from public.approbations where demande_id = p_demande and decision = 'validee';
  v_attendu := case when r.id is not null then r.roles_valideurs[v_nb + 1] end;
  if p_decision = 'validee' and v_attendu is not null and v_attendu <> v_role then
    raise exception 'Validation attendue d''abord du rôle « % ».', replace(v_attendu, '_', ' ') using errcode = '55000';
  end if;
  insert into public.approbations (demande_id, validateur_id, decision, commentaire) values (p_demande, v_client, p_decision, p_commentaire);
  if p_decision = 'refusee' then
    update public.demandes_approbation set statut = 'refusee' where id = p_demande;
    if d.type = 'virement' then
      update public.virements set statut = 'rejete', motif_rejet = 'Refusé lors de l''approbation' where id = d.objet_id;
    elsif d.type = 'note_de_frais' then
      update public.notes_de_frais set statut = 'refusee' where id = d.objet_id;
    end if;
    return jsonb_build_object('statut', 'refusee');
  end if;
  if v_nb + 1 >= coalesce(r.nb_validations, 1) then
    update public.demandes_approbation set statut = 'validee' where id = p_demande;
    if d.type = 'virement' then
      update public.virements set statut = 'valide', sca_le = now() where id = d.objet_id;
      return jsonb_build_object('statut', 'validee') || gmb_prive.executer_virement(d.objet_id);
    elsif d.type = 'note_de_frais' then
      update public.notes_de_frais set statut = 'validee' where id = d.objet_id;
    end if;
    return jsonb_build_object('statut', 'validee');
  end if;
  return jsonb_build_object('statut', 'en_attente', 'validations', v_nb + 1, 'requises', r.nb_validations);
end $$;

-- Note de frais (BIZ-06), soumise au circuit si une règle existe
create or replace function public.gmb_note_de_frais_soumettre(p_entreprise uuid, p_marchand text, p_montant numeric, p_tva numeric,
                                                              p_date date, p_justificatif text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_client uuid := gmb_prive.client_courant(); v_id uuid; v_regle record;
begin
  if not gmb_prive.membre_entreprise(p_entreprise) then
    raise exception 'Entreprise introuvable.' using errcode = '42501';
  end if;
  insert into public.notes_de_frais (entreprise_id, client_id, marchand, montant_ttc, tva, date_depense, justificatif_chemin)
  values (p_entreprise, v_client, p_marchand, p_montant, coalesce(p_tva, 0), p_date, p_justificatif) returning id into v_id;
  select * into v_regle from public.regles_approbation
   where entreprise_id = p_entreprise and type_operation = 'note_de_frais' and actif and p_montant > seuil order by seuil desc limit 1;
  if found then
    insert into public.demandes_approbation (entreprise_id, regle_id, type, objet_id, libelle, montant, demandeur_id)
    values (p_entreprise, v_regle.id, 'note_de_frais', v_id, 'Note de frais · ' || p_marchand, p_montant, v_client);
  else
    update public.notes_de_frais set statut = 'validee' where id = v_id;
  end if;
  return jsonb_build_object('note', v_id);
end $$;


-- ---------- 11.7 Espace Jeunes (parent) ---------------------------------------

create or replace function public.gmb_jeune_regler(p_compte_jeune uuid, p_reglages jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r jsonb;
begin
  update public.comptes_jeunes j set
    plafond_hebdo           = coalesce((p_reglages ->> 'plafond_hebdo')::numeric, plafond_hebdo),
    paiements_en_ligne      = coalesce((p_reglages ->> 'paiements_en_ligne')::boolean, paiements_en_ligne),
    retraits                = coalesce((p_reglages ->> 'retraits')::boolean, retraits),
    etranger                = coalesce((p_reglages ->> 'etranger')::boolean, etranger),
    alerte_paiement         = coalesce((p_reglages ->> 'alerte_paiement')::boolean, alerte_paiement),
    argent_de_poche_montant = coalesce((p_reglages ->> 'argent_de_poche_montant')::numeric, argent_de_poche_montant),
    argent_de_poche_jour    = coalesce((p_reglages ->> 'argent_de_poche_jour')::int, argent_de_poche_jour)
   where j.compte_id = p_compte_jeune and gmb_prive.client_courant() in (j.parent_client_id, j.second_parent_client_id)
  returning to_jsonb(j) into r;
  if r is null then
    raise exception 'Compte Jeunes introuvable.' using errcode = '42501';
  end if;
  return r;
end $$;

create or replace function public.gmb_jeune_envoyer(p_compte_jeune uuid, p_montant numeric)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare j record; v_source record; v_prenom text;
begin
  select * into j from public.comptes_jeunes
   where compte_id = p_compte_jeune and gmb_prive.client_courant() in (parent_client_id, second_parent_client_id);
  if not found then
    raise exception 'Compte Jeunes introuvable.' using errcode = '42501';
  end if;
  select * into v_source from public.comptes
   where client_id = gmb_prive.client_courant() and type = 'courant' and statut = 'actif' order by ouvert_le limit 1 for update;
  if p_montant is null or p_montant <= 0 or v_source.solde < p_montant then
    raise exception 'Montant invalide ou solde insuffisant.' using errcode = '22023';
  end if;
  select p.prenoms into v_prenom from public.clients c join public.personnes p on p.id = c.personne_id where c.id = gmb_prive.client_courant();
  insert into public.operations (compte_id, type, libelle, montant, categorie_code) values
    (v_source.id, 'argent_de_poche', 'Argent de poche', -p_montant, 'transferts'),
    (p_compte_jeune, 'argent_de_poche', 'Argent de poche de ' || coalesce(v_prenom, 'ton parent'), p_montant, 'transferts');
  perform gmb_prive.notifier(j.jeune_client_id, null, 'Argent de poche reçu',
    format('Tu as reçu %s € d''argent de poche.', gmb_prive.euros(p_montant)), null, 'push');
  return jsonb_build_object('statut', 'envoye', 'montant', p_montant);
end $$;


-- ---------- 11.8 Back-office ---------------------------------------------------

-- Ouverture du compte après validation (identifiant, IBAN, Livret, carte,
-- documents, versement crédité, déclaration FICOBA, code d'activation)
create or replace function gmb_prive.ouvrir_compte(p_dossier uuid)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare d record; f record; v record; e record; j record; v_client uuid; v_courant uuid; v_entreprise uuid; v_personne_enfant uuid; v_enfant uuid; v_compte_jeune uuid;
begin
  select * into d from public.dossiers where id = p_dossier;
  if d.etat = 'compte_ouvert' or exists (select 1 from public.clients where dossier_origine_id = p_dossier) then
    raise exception 'Le compte de ce dossier est déjà ouvert.' using errcode = '55000';
  end if;
  select * into f from public.formules where code = coalesce(d.formule_code, 'luna');
  select * into v from public.premiers_versements where dossier_id = p_dossier;
  if d.type = 'ouverture' and (not found or v.statut <> 'recu') then
    raise exception 'Le premier versement n''a pas encore été reçu : ouverture impossible.' using errcode = '55000';
  end if;
  insert into public.clients (personne_id, identifiant, segment, formule_code, dossier_origine_id, ficoba_declare_le)
  values (d.personne_id, gmb_prive.nouvel_identifiant(), case when d.segment = 'jeunes' then 'particulier' else d.segment end, f.code, p_dossier, now())
  returning id into v_client;
  if d.segment in ('pro', 'business') then
    select * into e from public.dossier_entreprises where dossier_id = p_dossier;
    if not found then
      raise exception 'Les informations de l''entreprise manquent : ouverture impossible.' using errcode = '55000';
    end if;
    if exists (select 1 from public.entreprises where siren = e.siren) then
      raise exception 'Une entreprise portant ce SIREN est déjà cliente.' using errcode = '23505';
    end if;
    insert into public.entreprises (raison_sociale, siren, forme, formule_code, adresse)
    values (e.raison_sociale, e.siren, e.forme_juridique, f.code, e.adresse_siege || ', ' || e.code_postal || ' ' || e.ville)
    returning id into v_entreprise;
    insert into public.entreprise_membres (entreprise_id, client_id, role, statut) values (v_entreprise, v_client, 'administrateur', 'actif');
  end if;
  if d.segment = 'business' then
    insert into public.comptes (entreprise_id, type, libelle, numero)
    values (v_entreprise, 'business', 'Compte Business', gmb_prive.nouveau_numero_compte())
    returning id into v_courant;
  else
    insert into public.comptes (client_id, type, libelle, numero)
    values (v_client, case when d.segment = 'pro' then 'pro' else 'courant' end,
            case when d.segment = 'pro' then 'Compte professionnel' else 'Compte courant' end, gmb_prive.nouveau_numero_compte())
    returning id into v_courant;
  end if;
  if f.taux_livret is not null and d.segment in ('particulier', 'jeunes') then
    insert into public.comptes (client_id, type, libelle, taux, plafond, numero)
    values (v_client, 'livret', 'Livret GMB', f.taux_livret, 100000, gmb_prive.nouveau_numero_compte());
  end if;
  if d.segment = 'jeunes' then
    select * into j from public.dossier_jeunes where dossier_id = p_dossier;
    if not found then
      raise exception 'Les informations de l''enfant manquent : ouverture impossible.' using errcode = '55000';
    end if;
    insert into public.personnes (civilite, nom_naissance, prenoms, date_naissance, lieu_naissance, pays_naissance, nationalite,
                                  adresse_ligne1, adresse_ligne2, code_postal, ville, pays, residence_fiscale)
    select j.civilite, j.nom, j.prenoms, j.date_naissance, j.lieu_naissance, j.pays_naissance, j.nationalite,
           p.adresse_ligne1, p.adresse_ligne2, p.code_postal, p.ville, p.pays, p.residence_fiscale
      from public.personnes p where p.id = d.personne_id
    returning id into v_personne_enfant;
    insert into public.clients (personne_id, identifiant, segment, formule_code)
    values (v_personne_enfant, gmb_prive.nouvel_identifiant(), 'jeunes', 'luna') returning id into v_enfant;
    insert into public.comptes (client_id, type, libelle, numero)
    values (v_enfant, 'jeune', 'Compte Jeunes', gmb_prive.nouveau_numero_compte()) returning id into v_compte_jeune;
    insert into public.comptes_jeunes (compte_id, jeune_client_id, parent_client_id) values (v_compte_jeune, v_enfant, v_client);
  end if;
  if v.statut = 'recu' then
    insert into public.operations (compte_id, type, libelle, montant, categorie_code)
    values (v_courant, 'versement_initial', 'Premier versement', coalesce(v.montant_recu, v.montant), 'transferts');
    update public.premiers_versements set statut = 'credite', credite_le = now() where dossier_id = p_dossier;
  end if;
  update public.dossiers set etat = 'compte_ouvert', ouvert_le = now() where id = p_dossier;
  perform gmb_prive.notifier(v_client, d.demandeur_auth, 'Votre compte est ouvert',
    'Votre identifiant bancaire est disponible dans l''Espace Mon Dossier. Activez ensuite votre accès : un code vous sera envoyé par e-mail.',
    '/mon-dossier/', 'email', 'MSG-COMPTE-OUVERT');
  return v_client;
end $$;

-- Prise en charge d'un dossier déposé (ADM-04, ADM-08)
create or replace function public.gmb_bo_dossier_prendre(p_dossier uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare d record;
begin
  select * into d from public.dossiers where id = p_dossier for update;
  if not found or not gmb_prive.bo_decision(case when d.type = 'credit' then 'ADM-08' else 'ADM-04' end) then
    raise exception 'Dossier introuvable ou droits insuffisants.' using errcode = '42501';
  end if;
  if d.etat not in ('depose', 'demande_deposee') then
    raise exception 'Ce dossier est déjà pris en charge.' using errcode = '55000';
  end if;
  update public.dossiers set etat = case when d.type = 'credit' then 'analyse' else 'en_verification' end, analyste_id = auth.uid()
   where id = p_dossier;
  return jsonb_build_object('etat', case when d.type = 'credit' then 'analyse' else 'en_verification' end);
end $$;

-- État d'une pièce (validée ou refusée avec un motif lisible par le client)
create or replace function public.gmb_bo_piece_statuer(p_piece uuid, p_statut text, p_motif_client text default null)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if not gmb_prive.bo_decision('ADM-04') then
    raise exception 'Droits insuffisants.' using errcode = '42501';
  end if;
  if p_statut not in ('validee', 'refusee', 'en_controle') then
    raise exception 'État de pièce inconnu.' using errcode = '22023';
  end if;
  update public.dossier_pieces
     set statut = p_statut, motif_refus_client = case when p_statut = 'refusee' then p_motif_client end, controle_le = now()
   where id = p_piece;
end $$;

-- Décision de l'analyste (ADM-04) : complément, conformité, validation (quatre
-- yeux au-delà du risque faible) ou refus sans motif détaillé pour le client
create or replace function public.gmb_bo_dossier_decision(p_dossier uuid, p_decision text, p_motif_code text default null,
                                                          p_message text default null, p_note text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare d record; v_risque text; v_nb int; v_msg text; v_client uuid;
begin
  select * into d from public.dossiers where id = p_dossier for update;
  if not found or not gmb_prive.bo_decision(case when d.type = 'credit' then 'ADM-08' else 'ADM-04' end) then
    raise exception 'Dossier introuvable ou droits insuffisants.' using errcode = '42501';
  end if;
  insert into public.dossier_notes_internes (dossier_id, auteur_id, decision, motif_code, note)
  values (p_dossier, auth.uid(), p_decision, p_motif_code, coalesce(p_note, p_decision));
  v_msg := coalesce(p_message, (select contenu from public.modeles_notification where code = p_motif_code));

  if p_decision = 'complement' then
    update public.dossiers
       set etat = 'incomplet',
           complement_avant = current_date + coalesce((select valeur::int from public.parametres_securite where cle = 'complement_delai_jours'), 30)
     where id = p_dossier;
    if v_msg is not null then
      insert into public.dossier_messages (dossier_id, auteur, auteur_id, contenu) values (p_dossier, 'conseiller', auth.uid(), v_msg);
    end if;
    return jsonb_build_object('etat', 'incomplet');

  elsif p_decision = 'conformite' then
    if d.type <> 'ouverture' then
      raise exception 'Décision réservée aux ouvertures de compte.' using errcode = '22023';
    end if;
    update public.dossiers set etat = 'analyse_conformite' where id = p_dossier;
    insert into public.alertes_lcbft (personne_id, dossier_id, type, gravite, details)
    values (d.personne_id, p_dossier, 'scenario', 'moyenne', jsonb_build_object('motif', p_motif_code));
    return jsonb_build_object('etat', 'analyse_conformite');

  elsif p_decision = 'refuser' then
    update public.dossiers set etat = case when d.type = 'credit' then 'refusee' else 'refuse' end, decision_le = now() where id = p_dossier;
    update public.premiers_versements set statut = 'rembourse', rembourse_le = now() where dossier_id = p_dossier and statut in ('recu', 'en_revue');
    insert into public.dossier_messages (dossier_id, auteur, contenu)
    values (p_dossier, 'systeme', coalesce((select contenu from public.modeles_notification where code = 'MSG-REFUS-01'),
                                           'Nous ne pouvons pas donner une suite favorable à votre demande.'));
    return jsonb_build_object('etat', case when d.type = 'credit' then 'refusee' else 'refuse' end);

  elsif p_decision = 'valider' then
    if d.type <> 'ouverture' then
      raise exception 'Pour un crédit, émettez une offre.' using errcode = '22023';
    end if;
    if d.etat = 'depose' then
      raise exception 'Prenez d''abord ce dossier en charge, avec le bouton « Prendre en charge ».' using errcode = '55000';
    end if;
    if d.etat not in ('en_verification', 'analyse_conformite') then
      raise exception 'Ce dossier ne peut pas être validé dans son état actuel : il doit être en vérification.' using errcode = '55000';
    end if;
    if exists (select 1 from (select distinct on (controle) resultat from public.dossier_controles
                               where dossier_id = p_dossier order by controle, created_at desc) x where x.resultat = 'non_conforme') then
      raise exception 'Un contrôle du dossier est en échec : validation impossible.' using errcode = '55000';
    end if;
    select count(*) into v_nb from public.dossier_pieces where dossier_id = p_dossier and statut in ('attendue', 'refusee', 'deposee', 'en_controle');
    if v_nb > 0 then
      raise exception 'Validation impossible : % pièce(s) du dossier ne sont pas encore validées.', v_nb using errcode = '55000';
    end if;
    if not exists (select 1 from public.premiers_versements where dossier_id = p_dossier and statut = 'recu') then
      raise exception 'Validation impossible : le premier versement n''est pas encore enregistré comme reçu (rubrique Trésorerie, ou bouton « Enregistrer la réception » du dossier).' using errcode = '55000';
    end if;
    select niveau into v_risque from public.profils_risque where personne_id = d.personne_id;
    insert into public.dossier_validations (dossier_id, analyste_id) values (p_dossier, auth.uid()) on conflict do nothing;
    select count(*) into v_nb from public.dossier_validations where dossier_id = p_dossier;
    if coalesce(v_risque, 'faible') <> 'faible' and v_nb < 2 then
      return jsonb_build_object('etat', d.etat, 'attente', 'second_validateur');
    end if;
    update public.dossiers set etat = 'valide', decision_le = now() where id = p_dossier;
    v_client := gmb_prive.ouvrir_compte(p_dossier);
    return jsonb_build_object('etat', 'compte_ouvert', 'client', v_client);
  end if;
  raise exception 'Décision inconnue.' using errcode = '22023';
end $$;

-- Offre de crédit (ADM-08) : FICP consulté, taux d'effort de 35 % au plus
create or replace function public.gmb_bo_credit_offre(p_id uuid, p_taux numeric default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare c record; d record; s jsonb; v_taux numeric; v_mens numeric;
begin
  if not gmb_prive.bo_decision('ADM-08') then
    raise exception 'Droits insuffisants.' using errcode = '42501';
  end if;
  select dc.*, ds.etat into c from public.dossier_credit dc join public.dossiers ds on ds.id = dc.dossier_id where dc.dossier_id = p_id;
  if found then
    if c.etat not in ('analyse', 'incomplet') then
      raise exception 'Le dossier doit être en analyse.' using errcode = '55000';
    end if;
    s := public.gmb_simuler_credit(c.montant, c.duree_mois, c.objet);
    v_taux := coalesce(p_taux, (s ->> 'taux_debiteur')::numeric);
    v_mens := gmb_prive.mensualite(c.montant, v_taux, c.duree_mois);
    if c.revenus_mensuels is not null and c.revenus_mensuels > 0
       and (coalesce(c.charges_mensuelles, 0) + v_mens) / c.revenus_mensuels > 0.35 then
      insert into public.dossier_controles (dossier_id, controle, resultat, details)
      values (p_id, 'solvabilite', 'non_conforme', jsonb_build_object('taux_effort', round((coalesce(c.charges_mensuelles, 0) + v_mens) / c.revenus_mensuels * 100, 1)));
      raise exception 'Taux d''effort supérieur à 35 %% : offre impossible.' using errcode = '55000';
    end if;
    update public.dossier_credit
       set taux_debiteur = v_taux, taeg = gmb_prive.taeg(v_taux), mensualite = v_mens, montant_total_du = v_mens * duree_mois,
           cout_total = v_mens * duree_mois - montant, ficp_consulte_le = now(), offre_emise_le = now()
     where dossier_id = p_id;
    insert into public.dossier_controles (dossier_id, controle, resultat) values (p_id, 'ficp', 'conforme'), (p_id, 'solvabilite', 'conforme');
    update public.dossiers set etat = 'offre_emise' where id = p_id;
    return jsonb_build_object('etat', 'offre_emise', 'mensualite', v_mens, 'taeg', gmb_prive.taeg(v_taux));
  end if;
  select * into d from public.demandes where id = p_id and type = 'pret_personnel' for update;
  if not found or d.etat not in ('demande_deposee', 'analyse', 'incomplet') then
    raise exception 'Demande de prêt introuvable ou déjà traitée.' using errcode = '55000';
  end if;
  v_taux := coalesce(p_taux, d.taux_debiteur);
  v_mens := gmb_prive.mensualite(d.montant, v_taux, d.duree_mois);
  update public.demandes
     set etat = 'offre_emise', taux_debiteur = v_taux, taeg = gmb_prive.taeg(v_taux), mensualite = v_mens,
         montant_total_du = v_mens * duree_mois, cout_total = v_mens * duree_mois - montant, offre_emise_le = now()
   where id = p_id;
  return jsonb_build_object('etat', 'offre_emise', 'mensualite', v_mens, 'taeg', gmb_prive.taeg(v_taux));
end $$;

-- Tableau d'amortissement
create or replace function gmb_prive.generer_echeancier(p_credit uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; v_crd numeric; i int; v_int numeric; v_cap numeric;
begin
  select * into c from public.credits where id = p_credit;
  v_crd := c.montant;
  for i in 1..c.duree_mois loop
    v_int := round(v_crd * c.taux_debiteur / 1200, 2);
    v_cap := case when i = c.duree_mois then v_crd else c.mensualite - v_int end;
    v_crd := v_crd - v_cap;
    insert into public.credit_echeances (credit_id, numero, date_echeance, capital, interets, montant, capital_restant)
    values (p_credit, i, (c.debut + make_interval(months => i))::date, v_cap, v_int, v_cap + v_int, v_crd);
  end loop;
end $$;

-- Versement des fonds (ADM-08), jamais avant le 8e jour suivant l'acceptation
create or replace function public.gmb_bo_credit_debloquer(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare d record; v_compte uuid; v_credit uuid;
begin
  if not gmb_prive.bo_decision('ADM-08') then
    raise exception 'Droits insuffisants.' using errcode = '42501';
  end if;
  if exists (select 1 from public.dossiers where id = p_id and type = 'credit') then
    if (select etat from public.dossiers where id = p_id) <> 'delai_legal'
       or current_date < (select deblocage_possible_le::date from public.dossier_credit where dossier_id = p_id) then
      raise exception 'Versement impossible avant le 8e jour suivant l''acceptation.' using errcode = '55000';
    end if;
    update public.dossiers set etat = 'acceptee' where id = p_id;
    update public.dossier_credit set fonds_debloques_le = now() where dossier_id = p_id;
    update public.dossiers set etat = 'fonds_debloques' where id = p_id;
    return jsonb_build_object('etat', 'fonds_debloques');
  end if;
  select * into d from public.demandes where id = p_id and type = 'pret_personnel' for update;
  if not found or d.etat <> 'delai_legal' or current_date < d.deblocage_possible_le::date then
    raise exception 'Versement impossible avant le 8e jour suivant l''acceptation.' using errcode = '55000';
  end if;
  select id into v_compte from public.comptes where client_id = d.client_id and type = 'courant' and statut = 'actif' order by ouvert_le limit 1;
  update public.demandes set etat = 'acceptee' where id = p_id;
  update public.demandes set etat = 'fonds_debloques', fonds_debloques_le = now() where id = p_id;
  insert into public.credits (client_id, demande_id, compte_id, montant, duree_mois, taux_debiteur, taeg, mensualite, debut, capital_restant)
  values (d.client_id, d.id, v_compte, d.montant, d.duree_mois, d.taux_debiteur, d.taeg, d.mensualite, current_date, d.montant)
  returning id into v_credit;
  perform gmb_prive.generer_echeancier(v_credit);
  insert into public.operations (compte_id, type, libelle, montant, categorie_code)
  values (v_compte, 'credit', 'Prêt personnel ' || d.reference, d.montant, 'transferts');
  return jsonb_build_object('etat', 'fonds_debloques', 'credit', v_credit);
end $$;

-- Circuit de publication d'une page (ADM-02) : rédaction, relecture
-- conformité, validation juridique si un bloc réglementé est modifié
create or replace function public.gmb_bo_cms_statut(p_page uuid, p_statut text, p_planifiee_le timestamptz default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare pg record; v_relecteur uuid; v_approbateur uuid;
begin
  select * into pg from public.cms_pages where id = p_page for update;
  if not found then
    raise exception 'Page introuvable.' using errcode = 'P0002';
  end if;
  v_relecteur := pg.relecteur_id;
  v_approbateur := pg.approbateur_id;
  if p_statut in ('brouillon', 'relecture_conformite', 'archivee') then
    if not gmb_prive.bo_ecriture('ADM-02') then
      raise exception 'Droits insuffisants.' using errcode = '42501';
    end if;
  elsif pg.statut = 'relecture_conformite' and p_statut in ('validation_juridique', 'planifiee', 'publiee') then
    if not gmb_prive.a_role('conformite') then
      raise exception 'Relecture réservée à la conformité.' using errcode = '42501';
    end if;
    v_relecteur := auth.uid();
  elsif pg.statut = 'validation_juridique' and p_statut in ('planifiee', 'publiee') then
    if not gmb_prive.a_role('juridique') then
      raise exception 'Validation réservée au service juridique.' using errcode = '42501';
    end if;
    v_approbateur := auth.uid();
  else
    raise exception 'Transition non autorisée : % → %.', pg.statut, p_statut using errcode = '55000';
  end if;
  update public.cms_pages
     set statut = p_statut, relecteur_id = v_relecteur, approbateur_id = v_approbateur,
         planifiee_le = coalesce(p_planifiee_le, planifiee_le),
         en_ligne = case when p_statut = 'archivee' then false else en_ligne end
   where id = p_page;
  return jsonb_build_object('statut', p_statut);
end $$;

-- Paramètre de sécurité (ADM-12) : bornes réglementaires contrôlées par la table
create or replace function public.gmb_bo_parametre_modifier(p_cle text, p_valeur numeric, p_motif text)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if not gmb_prive.bo_ecriture('ADM-12') then
    raise exception 'Droits insuffisants.' using errcode = '42501';
  end if;
  if p_motif is null or length(p_motif) < 5 then
    raise exception 'Indiquez le motif de la modification.' using errcode = '22023';
  end if;
  update public.parametres_securite set valeur = p_valeur, modifie_par = auth.uid(), modifie_le = now() where cle = p_cle;
  if not found then
    raise exception 'Paramètre inconnu.' using errcode = 'P0002';
  end if;
  insert into public.journal_audit (acteur_id, acteur_type, action, objet_type, objet_id, apres, motif)
  values (auth.uid(), 'backoffice', 'PARAMETRE', 'parametres_securite', p_cle, jsonb_build_object('valeur', p_valeur), p_motif);
end $$;

-- Remboursement d'une contestation (ADM-06)
create or replace function public.gmb_bo_contestation_rembourser(p_contestation uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare k record; v_compte uuid;
begin
  if not gmb_prive.bo_ecriture('ADM-06') then
    raise exception 'Droits insuffisants.' using errcode = '42501';
  end if;
  select * into k from public.contestations where id = p_contestation and statut = 'ouverte' for update;
  if not found then
    raise exception 'Contestation introuvable ou déjà traitée.' using errcode = 'P0002';
  end if;
  select compte_id into v_compte from public.operations where id = k.operation_id;
  insert into public.operations (compte_id, type, libelle, montant, categorie_code, reference)
  values (v_compte, 'remboursement', 'Remboursement d''une opération contestée', k.montant, 'transferts', k.operation_id::text);
  update public.contestations set statut = 'remboursee', rembourse_le = now() where id = p_contestation;
  return jsonb_build_object('statut', 'remboursee', 'dans_les_delais', now() <= k.rembourser_avant);
end $$;

-- Traitement d'une alerte LCB-FT (ADM-05) ou de fraude (ADM-06)
create or replace function public.gmb_bo_alerte_traiter(p_type text, p_alerte uuid, p_statut text, p_note text default null)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if p_type = 'lcbft' then
    if not gmb_prive.bo_ecriture('ADM-05') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
    update public.alertes_lcbft set statut = p_statut, traitee_le = now(),
           details = details || jsonb_build_object('note', p_note, 'par', auth.uid()) where id = p_alerte;
  elsif p_type = 'fraude' then
    if not gmb_prive.bo_ecriture('ADM-06') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
    update public.alertes_fraude set statut = p_statut, traitee_le = now(),
           details = details || jsonb_build_object('note', p_note, 'par', auth.uid()) where id = p_alerte;
  else
    raise exception 'Type d''alerte inconnu.' using errcode = '22023';
  end if;
end $$;

-- Nom comparable d'une société ou d'un titulaire : sans accents ni forme juridique
create or replace function gmb_prive.nom_societe(p_nom text) returns text
language sql immutable set search_path = '' as $$
  select btrim(regexp_replace(regexp_replace(gmb_prive.normaliser_nom(p_nom),
    '\m(SASU|SAS|SARL|EURL|SA|SNC|SCI|SELARL|SELAS|EIRL|EI)\M', ' ', 'g'), '\s+', ' ', 'g'))
$$;

-- =============================================================================
-- 16. OUVERTURE DES COMPTES PRO ET BUSINESS (lot 2)
-- =============================================================================

-- Entreprise d'une demande d'ouverture Pro ou Business (connaissance de l'entreprise)
create table if not exists public.dossier_entreprises (
  dossier_id        uuid primary key references public.dossiers(id) on delete cascade,
  raison_sociale    text not null,
  siren             text not null check (siren ~ '^[0-9]{9}$'),
  forme_juridique   text not null check (forme_juridique in ('ei', 'micro', 'eurl', 'sarl', 'sasu', 'sas', 'sa', 'snc', 'sci', 'association', 'autre')),
  date_creation     date,
  code_naf          text check (code_naf is null or code_naf ~ '^[0-9]{2}\.[0-9]{2}[A-Z]$'),
  activite          text,
  adresse_siege     text not null,
  code_postal       text not null check (code_postal ~ '^[0-9]{5}$'),
  ville             text not null,
  effectif          text check (effectif is null or effectif in ('0', '1_9', '10_49', '50_249', '250_plus')),
  chiffre_affaires  text check (chiffre_affaires is null or chiffre_affaires in ('moins_100k', '100k_1m', '1m_10m', 'plus_10m')),
  role_demandeur    text not null default 'dirigeant' check (role_demandeur in ('dirigeant', 'mandataire')),
  beneficiaires     jsonb not null default '[]'::jsonb,
  maj_le            timestamptz not null default now()
);
comment on table public.dossier_entreprises is 'GMB : entreprise d''une demande d''ouverture Pro ou Business (raison sociale, SIREN, siège, bénéficiaires effectifs).';

-- Enregistrement de l'entreprise par le demandeur (ONB-P, ONB-B)
create or replace function public.gmb_dossier_maj_entreprise(p_dossier uuid, p_donnees jsonb)
returns void
language plpgsql volatile security definer set search_path = '' as $$
declare d record; v_siren text := replace(coalesce(p_donnees ->> 'siren', ''), ' ', ''); v_forme text := p_donnees ->> 'forme_juridique';
  b jsonb; v_total numeric := 0;
begin
  if not gmb_prive.dossier_du_demandeur(p_dossier) then
    raise exception 'Dossier introuvable.' using errcode = '42501';
  end if;
  select * into d from public.dossiers where id = p_dossier;
  if d.segment not in ('pro', 'business') then
    raise exception 'Cette demande ne concerne pas une entreprise.' using errcode = '22023';
  end if;
  if d.etat not in ('brouillon', 'incomplet') then
    raise exception 'Ce dossier ne peut plus être modifié.' using errcode = '55000';
  end if;
  if v_siren !~ '^[0-9]{9}$' or not gmb_prive.luhn_valide(v_siren) then
    raise exception 'Ce numéro SIREN n''est pas valide : vérifiez les 9 chiffres.' using errcode = '22023';
  end if;
  if exists (select 1 from public.entreprises where siren = v_siren) then
    raise exception 'Cette entreprise est déjà cliente de GerMoonBank : demandez à son administrateur de vous inviter depuis l''Espace Business.' using errcode = '23505';
  end if;
  if coalesce(trim(p_donnees ->> 'raison_sociale'), '') = '' then
    raise exception 'Indiquez la dénomination de l''entreprise.' using errcode = '22023';
  end if;
  if d.segment = 'pro' and v_forme not in ('ei', 'micro', 'eurl', 'sasu') then
    raise exception 'L''offre Pro est réservée aux entrepreneurs individuels, micro-entrepreneurs, EURL et SASU.' using errcode = '22023';
  end if;
  if d.segment = 'business' and v_forme in ('ei', 'micro') then
    raise exception 'Pour une entreprise individuelle, choisissez l''offre Pro.' using errcode = '22023';
  end if;
  if d.segment = 'business' then
    if jsonb_typeof(p_donnees -> 'beneficiaires') <> 'array' or jsonb_array_length(p_donnees -> 'beneficiaires') = 0 then
      raise exception 'Déclarez au moins un bénéficiaire effectif.' using errcode = '22023';
    end if;
    for b in select * from jsonb_array_elements(p_donnees -> 'beneficiaires') loop
      if coalesce(trim(b ->> 'nom'), '') = '' or coalesce(trim(b ->> 'prenoms'), '') = '' or (b ->> 'date_naissance') is null then
        raise exception 'Indiquez le nom, les prénoms et la date de naissance de chaque bénéficiaire effectif.' using errcode = '22023';
      end if;
      v_total := v_total + coalesce((b ->> 'pourcentage')::numeric, 0);
    end loop;
    if v_total > 100 then
      raise exception 'Le total des parts déclarées dépasse 100 %%.' using errcode = '22023';
    end if;
  end if;
  insert into public.dossier_entreprises (dossier_id, raison_sociale, siren, forme_juridique, date_creation, code_naf, activite,
    adresse_siege, code_postal, ville, effectif, chiffre_affaires, role_demandeur, beneficiaires, maj_le)
  values (p_dossier, trim(p_donnees ->> 'raison_sociale'), v_siren, v_forme, nullif(p_donnees ->> 'date_creation', '')::date,
    nullif(upper(p_donnees ->> 'code_naf'), ''), nullif(trim(coalesce(p_donnees ->> 'activite', '')), ''),
    trim(p_donnees ->> 'adresse_siege'), p_donnees ->> 'code_postal', trim(p_donnees ->> 'ville'),
    nullif(p_donnees ->> 'effectif', ''), nullif(p_donnees ->> 'chiffre_affaires', ''),
    coalesce(nullif(p_donnees ->> 'role_demandeur', ''), 'dirigeant'), coalesce(p_donnees -> 'beneficiaires', '[]'::jsonb), now())
  on conflict (dossier_id) do update set raison_sociale = excluded.raison_sociale, siren = excluded.siren,
    forme_juridique = excluded.forme_juridique, date_creation = excluded.date_creation, code_naf = excluded.code_naf,
    activite = excluded.activite, adresse_siege = excluded.adresse_siege, code_postal = excluded.code_postal,
    ville = excluded.ville, effectif = excluded.effectif, chiffre_affaires = excluded.chiffre_affaires,
    role_demandeur = excluded.role_demandeur, beneficiaires = excluded.beneficiaires, maj_le = now();
  update public.dossiers set derniere_activite = now() where id = p_dossier;
end $$;

-- =============================================================================
-- 17. OUVERTURE DES COMPTES JEUNES (lot C)
-- =============================================================================

-- Enfant d'une demande d'ouverture Jeunes, déposée par un parent
create table if not exists public.dossier_jeunes (
  dossier_id          uuid primary key references public.dossiers(id) on delete cascade,
  civilite            text not null check (civilite in ('madame', 'monsieur')),
  nom                 text not null,
  prenoms             text not null,
  date_naissance      date not null,
  lieu_naissance      text not null,
  pays_naissance      text not null default 'FR',
  nationalite         text not null default 'FR',
  lien                text not null check (lien in ('mere', 'pere', 'tuteur')),
  autorite_parentale  boolean not null check (autorite_parentale),
  maj_le              timestamptz not null default now()
);
comment on table public.dossier_jeunes is 'GMB : enfant d''une demande d''ouverture Jeunes (identité, lien avec le parent demandeur).';

create or replace function public.gmb_dossier_maj_jeune(p_dossier uuid, p_donnees jsonb)
returns void
language plpgsql volatile security definer set search_path = '' as $$
declare d record; v_naissance date; v_age int;
begin
  if not gmb_prive.dossier_du_demandeur(p_dossier) then
    raise exception 'Dossier introuvable.' using errcode = '42501';
  end if;
  select * into d from public.dossiers where id = p_dossier;
  if d.segment <> 'jeunes' then
    raise exception 'Cette demande ne concerne pas un compte Jeunes.' using errcode = '22023';
  end if;
  if d.etat not in ('brouillon', 'incomplet') then
    raise exception 'Ce dossier ne peut plus être modifié.' using errcode = '55000';
  end if;
  if coalesce(trim(p_donnees ->> 'nom'), '') = '' or coalesce(trim(p_donnees ->> 'prenoms'), '') = '' or coalesce(trim(p_donnees ->> 'lieu_naissance'), '') = '' then
    raise exception 'Indiquez le nom, les prénoms et le lieu de naissance de votre enfant.' using errcode = '22023';
  end if;
  begin
    v_naissance := (p_donnees ->> 'date_naissance')::date;
  exception when others then
    raise exception 'Indiquez la date de naissance de votre enfant.' using errcode = '22023';
  end;
  v_age := extract(year from age(current_date, v_naissance))::int;
  if v_naissance is null or v_age < 10 or v_age > 17 then
    raise exception 'Le compte Jeunes est réservé aux enfants de 10 à 17 ans.' using errcode = '22023';
  end if;
  if coalesce(p_donnees ->> 'lien', '') not in ('mere', 'pere', 'tuteur') then
    raise exception 'Indiquez votre lien avec l''enfant.' using errcode = '22023';
  end if;
  if coalesce((p_donnees ->> 'autorite_parentale')::boolean, false) is not true then
    raise exception 'Vous devez exercer l''autorité parentale sur l''enfant pour ouvrir son compte.' using errcode = '22023';
  end if;
  insert into public.dossier_jeunes (dossier_id, civilite, nom, prenoms, date_naissance, lieu_naissance, pays_naissance, nationalite, lien, autorite_parentale, maj_le)
  values (p_dossier, coalesce(nullif(p_donnees ->> 'civilite', ''), 'monsieur'), upper(trim(p_donnees ->> 'nom')), trim(p_donnees ->> 'prenoms'), v_naissance,
          trim(p_donnees ->> 'lieu_naissance'), coalesce(nullif(p_donnees ->> 'pays_naissance', ''), 'FR'), coalesce(nullif(p_donnees ->> 'nationalite', ''), 'FR'),
          p_donnees ->> 'lien', true, now())
  on conflict (dossier_id) do update set civilite = excluded.civilite, nom = excluded.nom, prenoms = excluded.prenoms,
    date_naissance = excluded.date_naissance, lieu_naissance = excluded.lieu_naissance, pays_naissance = excluded.pays_naissance,
    nationalite = excluded.nationalite, lien = excluded.lien, autorite_parentale = true, maj_le = now();
  update public.dossiers set derniere_activite = now() where id = p_dossier;
end $$;

-- =============================================================================
-- 18. CODE SECRET OUBLIÉ OU BLOQUÉ (lot C2)
-- =============================================================================

-- Après vérification par la fonction serveur du code reçu par e-mail : nouveau code
-- secret (mêmes règles de solidité que l'activation) et levée des blocages.
create or replace function public.gmb_code_secret_reinitialiser(p_identifiant text, p_nouveau_code text)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_client uuid; v_lie uuid;
begin
  select id, auth_user_id into v_client, v_lie from public.clients where identifiant = p_identifiant and statut = 'actif';
  if v_client is null or v_lie is null then
    return jsonb_build_object('statut', 'inconnu');
  end if;
  perform gmb_prive.definir_code(v_client, p_nouveau_code);
  update gmb_prive.etat_connexion
     set echecs_consecutifs = 0, echecs_24h = 0, bloque_jusqu = null, bloque_definitif = false, maj_le = now()
   where identifiant = p_identifiant;
  return jsonb_build_object('statut', 'ok', 'client_id', v_client, 'auth_user_id', v_lie);
end $$;

-- =============================================================================
-- 19. BACK-OFFICE : MESSAGES, RÉCLAMATIONS, COLLABORATEURS (lot D)
-- =============================================================================

-- Réponse d'un conseiller dans l'Espace Mon Dossier (dossier d'ouverture ou de crédit)
create or replace function public.gmb_bo_dossier_message(p_dossier uuid, p_contenu text)
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare v_type text; v_id uuid;
begin
  select type into v_type from public.dossiers where id = p_dossier;
  if v_type is null then raise exception 'Dossier introuvable.' using errcode = '22023'; end if;
  if not gmb_prive.bo_decision(case when v_type = 'credit' then 'ADM-08' else 'ADM-04' end) then
    raise exception 'Droits insuffisants.' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_contenu, ''))) < 2 then raise exception 'Écrivez votre message.' using errcode = '22023'; end if;
  insert into public.dossier_messages (dossier_id, auteur, auteur_id, contenu) values (p_dossier, 'conseiller', auth.uid(), trim(p_contenu)) returning id into v_id;
  return v_id;
end $$;

-- Réponse d'un conseiller dans la messagerie de l'Espace client
create or replace function public.gmb_bo_message(p_fil uuid, p_contenu text, p_clore boolean default false)
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not gmb_prive.bo_decision('ADM-09') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
  if not exists (select 1 from public.fils_messagerie where id = p_fil) then raise exception 'Conversation introuvable.' using errcode = '22023'; end if;
  if length(trim(coalesce(p_contenu, ''))) < 2 then raise exception 'Écrivez votre message.' using errcode = '22023'; end if;
  insert into public.messages (fil_id, auteur, auteur_id, contenu) values (p_fil, 'conseiller', auth.uid(), trim(p_contenu)) returning id into v_id;
  update public.fils_messagerie set statut = case when p_clore then 'clos' else 'en_attente_client' end, updated_at = now() where id = p_fil;
  return v_id;
end $$;

-- Réclamation : accusé de réception, puis réponse (et clôture)
create or replace function public.gmb_bo_reclamation_accuser(p_reclamation uuid)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if not gmb_prive.bo_decision('ADM-09') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
  update public.reclamations set statut = 'en_cours', accuse_le = coalesce(accuse_le, now()) where id = p_reclamation and statut = 'recue';
  if not found and not exists (select 1 from public.reclamations where id = p_reclamation) then raise exception 'Réclamation introuvable.' using errcode = '22023'; end if;
end $$;

create or replace function public.gmb_bo_reclamation_repondre(p_reclamation uuid, p_reponse text, p_clore boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r record;
begin
  if not gmb_prive.bo_decision('ADM-09') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
  if length(trim(coalesce(p_reponse, ''))) < 20 then raise exception 'Rédigez une réponse complète (20 caractères au moins).' using errcode = '22023'; end if;
  select * into r from public.reclamations where id = p_reclamation;
  if not found then raise exception 'Réclamation introuvable.' using errcode = '22023'; end if;
  if r.statut = 'close' then raise exception 'Cette réclamation est close.' using errcode = '55000'; end if;
  update public.reclamations
     set reponse = trim(p_reponse), repondue_le = now(), accuse_le = coalesce(accuse_le, now()),
         statut = case when p_clore then 'close' else 'repondue' end
   where id = p_reclamation;
  return jsonb_build_object('statut', case when p_clore then 'close' else 'repondue' end, 'dans_les_delais', now() <= coalesce(r.reponse_avant, now()));
end $$;

-- Collaborateurs : rôles et activation (habilitations, ADM-13)
create or replace function public.gmb_bo_collaborateur_role(p_collaborateur uuid, p_role text, p_attribuer boolean)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if not gmb_prive.bo_decision('ADM-13') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
  if p_collaborateur = auth.uid() then raise exception 'Vous ne pouvez pas modifier vos propres rôles.' using errcode = '42501'; end if;
  if not exists (select 1 from public.collaborateurs where id = p_collaborateur) then raise exception 'Collaborateur introuvable.' using errcode = '22023'; end if;
  if not exists (select 1 from public.roles_bo where code = p_role) then raise exception 'Rôle inconnu.' using errcode = '22023'; end if;
  if p_attribuer then
    insert into public.collaborateur_roles (collaborateur_id, role_code) values (p_collaborateur, p_role) on conflict do nothing;
  else
    delete from public.collaborateur_roles where collaborateur_id = p_collaborateur and role_code = p_role;
  end if;
end $$;

-- GerMoonBank · installation de la base, partie 5 sur 8
-- Exécutez les parties dans l'ordre, chacune dans une requête vide du SQL Editor.
-- Contenu : 03_fonctions
create or replace function public.gmb_bo_collaborateur_actif(p_collaborateur uuid, p_actif boolean)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if not gmb_prive.bo_decision('ADM-13') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
  if p_collaborateur = auth.uid() then raise exception 'Vous ne pouvez pas modifier votre propre accès.' using errcode = '42501'; end if;
  update public.collaborateurs set actif = p_actif where id = p_collaborateur;
  if not found then raise exception 'Collaborateur introuvable.' using errcode = '22023'; end if;
end $$;

-- =============================================================================
-- 20. BACK-OFFICE, SECONDE PARTIE (lot D2)
-- =============================================================================

-- État des services : géré par la sécurité (ADM-12) ; aucun rôle n'a l'écriture sur ADM-01
create or replace function public.gmb_bo_service_etat(p_service text, p_etat text, p_message text default null)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
begin
  if not gmb_prive.bo_ecriture('ADM-12') then
    raise exception 'Droits insuffisants.' using errcode = '42501';
  end if;
  update public.statut_services set etat = p_etat, message = nullif(trim(coalesce(p_message, '')), ''), maj_le = now() where service = p_service;
  if not found then
    raise exception 'Service inconnu.' using errcode = '22023';
  end if;
  return jsonb_build_object('service', p_service, 'etat', p_etat);
end $$;

-- Contestation refusée (ADM-06), motif tracé au journal d'audit
create or replace function public.gmb_bo_contestation_refuser(p_contestation uuid, p_motif text)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if not gmb_prive.bo_ecriture('ADM-06') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
  if length(trim(coalesce(p_motif, ''))) < 10 then raise exception 'Indiquez le motif du refus (10 caractères au moins).' using errcode = '22023'; end if;
  update public.contestations set statut = 'refusee' where id = p_contestation and statut = 'ouverte';
  if not found then raise exception 'Contestation introuvable ou déjà traitée.' using errcode = 'P0002'; end if;
  insert into public.journal_audit (acteur_id, acteur_type, action, objet_type, objet_id, avant, apres, motif) values (auth.uid(), 'backoffice', 'CONTESTATION_REFUSEE', 'contestations', p_contestation::text, null, jsonb_build_object('statut', 'refusee'), trim(p_motif));
end $$;

-- Client actif, inactif ou bloqué (ADM-07) ; un client bloqué ne peut plus se connecter
create or replace function public.gmb_bo_client_statut(p_client uuid, p_statut text, p_motif text)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare v_avant text;
begin
  if not gmb_prive.bo_ecriture('ADM-07') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
  if p_statut not in ('actif', 'inactif', 'bloque') then raise exception 'Statut inconnu.' using errcode = '22023'; end if;
  if length(trim(coalesce(p_motif, ''))) < 5 then raise exception 'Indiquez le motif.' using errcode = '22023'; end if;
  select statut into v_avant from public.clients where id = p_client and statut <> 'cloture' for update;
  if not found then raise exception 'Client introuvable ou clôturé.' using errcode = 'P0002'; end if;
  update public.clients set statut = p_statut, updated_at = now() where id = p_client;
  insert into public.journal_audit (acteur_id, acteur_type, action, objet_type, objet_id, avant, apres, motif) values (auth.uid(), 'backoffice', 'CLIENT_STATUT', 'clients', p_client::text, jsonb_build_object('statut', v_avant), jsonb_build_object('statut', p_statut), trim(p_motif));
end $$;

-- Incidents (DORA, ADM-12) : un incident majeur fixe les échéances de notification
create or replace function public.gmb_bo_incident_declarer(p_titre text, p_description text, p_classification text, p_services text[] default '{}', p_public boolean default false)
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare v_id uuid; v_majeur boolean := p_classification = 'majeur';
begin
  if not gmb_prive.bo_ecriture('ADM-12') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
  if p_classification not in ('mineur', 'significatif', 'majeur') then raise exception 'Classification inconnue.' using errcode = '22023'; end if;
  if length(trim(coalesce(p_titre, ''))) < 5 then raise exception 'Indiquez un titre (5 caractères au moins).' using errcode = '22023'; end if;
  insert into public.incidents (titre, description, classification, services, detecte_le, classe_le, notif_initiale_avant, rapport_intermediaire_avant, rapport_final_avant, statut, public)
  values (trim(p_titre), nullif(trim(coalesce(p_description, '')), ''), p_classification, coalesce(p_services, '{}'), now(), now(),
          case when v_majeur then now() + interval '4 hours' end, case when v_majeur then now() + interval '72 hours' end, case when v_majeur then now() + interval '1 month' end,
          'ouvert', coalesce(p_public, false))
  returning id into v_id;
  insert into public.journal_audit (acteur_id, acteur_type, action, objet_type, objet_id, avant, apres, motif) values (auth.uid(), 'backoffice', 'INCIDENT_DECLARE', 'incidents', v_id::text, null, jsonb_build_object('classification', p_classification, 'public', coalesce(p_public, false)), null);
  return v_id;
end $$;

create or replace function public.gmb_bo_incident_statut(p_incident uuid, p_statut text, p_public boolean default null)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if not gmb_prive.bo_ecriture('ADM-12') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
  if p_statut not in ('ouvert', 'en_cours', 'resolu', 'clos') then raise exception 'Statut inconnu.' using errcode = '22023'; end if;
  update public.incidents
     set statut = p_statut, public = coalesce(p_public, public),
         resolu_le = case when p_statut in ('resolu', 'clos') then coalesce(resolu_le, now()) else null end
   where id = p_incident;
  if not found then raise exception 'Incident introuvable.' using errcode = 'P0002'; end if;
  insert into public.journal_audit (acteur_id, acteur_type, action, objet_type, objet_id, avant, apres, motif) values (auth.uid(), 'backoffice', 'INCIDENT_STATUT', 'incidents', p_incident::text, null, jsonb_build_object('statut', p_statut), null);
end $$;

-- Contenus (ADM-02) : seul un brouillon se modifie
create or replace function public.gmb_bo_cms_modifier(p_page uuid, p_titre text, p_description_seo text, p_blocs jsonb default null)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare v_statut text;
begin
  if not gmb_prive.bo_ecriture('ADM-02') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
  select statut into v_statut from public.cms_pages where id = p_page for update;
  if not found then raise exception 'Page introuvable.' using errcode = 'P0002'; end if;
  if v_statut <> 'brouillon' then raise exception 'Seul un brouillon se modifie : repassez d''abord la page en brouillon.' using errcode = '55000'; end if;
  if length(trim(coalesce(p_titre, ''))) < 3 then raise exception 'Indiquez un titre.' using errcode = '22023'; end if;
  if char_length(coalesce(p_description_seo, '')) > 155 then raise exception 'La description ne doit pas dépasser 155 caractères.' using errcode = '22023'; end if;
  if p_blocs is not null and jsonb_typeof(p_blocs) <> 'array' then raise exception 'Les blocs doivent former une liste JSON.' using errcode = '22023'; end if;
  update public.cms_pages
     set titre = trim(p_titre), description_seo = nullif(trim(coalesce(p_description_seo, '')), ''), blocs_brouillon = coalesce(p_blocs, blocs_brouillon), auteur_id = auth.uid(), updated_at = now()
   where id = p_page;
end $$;

-- Catalogue, tarifs et taux (ADM-03)
create or replace function public.gmb_bo_frais_modifier(p_code text, p_montant numeric, p_pourcentage numeric, p_motif text)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare v_avant jsonb;
begin
  if not gmb_prive.bo_ecriture('ADM-03') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
  if length(trim(coalesce(p_motif, ''))) < 5 then raise exception 'Indiquez le motif de la modification.' using errcode = '22023'; end if;
  if coalesce(p_montant, 0) < 0 or coalesce(p_pourcentage, 0) < 0 then raise exception 'Un frais ne peut pas être négatif.' using errcode = '22023'; end if;
  select to_jsonb(f) into v_avant from public.frais f where code = p_code for update;
  if v_avant is null then raise exception 'Frais inconnu.' using errcode = 'P0002'; end if;
  update public.frais set montant = p_montant, pourcentage = p_pourcentage, updated_at = now() where code = p_code;
  insert into public.journal_audit (acteur_id, acteur_type, action, objet_type, objet_id, avant, apres, motif) values (auth.uid(), 'backoffice', 'FRAIS_MODIFIE', 'frais', p_code, v_avant, jsonb_build_object('montant', p_montant, 'pourcentage', p_pourcentage), trim(p_motif));
end $$;

create or replace function public.gmb_bo_grille_credit_taux(p_id uuid, p_taux numeric, p_motif text)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare g record; v_usure numeric;
begin
  if not gmb_prive.bo_ecriture('ADM-03') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
  if length(trim(coalesce(p_motif, ''))) < 5 then raise exception 'Indiquez le motif de la modification.' using errcode = '22023'; end if;
  select * into g from public.grilles_credit where id = p_id for update;
  if not found then raise exception 'Grille introuvable.' using errcode = 'P0002'; end if;
  select taux into v_usure from public.taux_usure where categorie = g.categorie_usure and current_date between valable_du and valable_au order by valable_du desc limit 1;
  if v_usure is null then raise exception 'Aucun taux d''usure en vigueur pour cette catégorie : enregistrez-le d''abord.' using errcode = '55000'; end if;
  if p_taux is null or p_taux <= 0 or p_taux >= v_usure then
    raise exception 'Le taux doit être positif et inférieur au taux d''usure en vigueur (% %%).', replace(v_usure::text, '.', ',') using errcode = '22023';
  end if;
  update public.grilles_credit set taux_debiteur = p_taux, valide_conformite = false, updated_at = now() where id = p_id;
  insert into public.journal_audit (acteur_id, acteur_type, action, objet_type, objet_id, avant, apres, motif) values (auth.uid(), 'backoffice', 'GRILLE_CREDIT_TAUX', 'grilles_credit', p_id::text, jsonb_build_object('taux_debiteur', g.taux_debiteur), jsonb_build_object('taux_debiteur', p_taux), trim(p_motif));
end $$;

-- Validation par la conformité, par une autre personne que l'auteur de la modification
create or replace function public.gmb_bo_grille_credit_valider(p_id uuid)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare v_auteur uuid;
begin
  if not (gmb_prive.a_role('conformite') and gmb_prive.droit_bo('ADM-03', array['V', 'A'])) then
    raise exception 'Validation réservée à la conformité.' using errcode = '42501';
  end if;
  select acteur_id into v_auteur from public.journal_audit where action = 'GRILLE_CREDIT_TAUX' and objet_id = p_id::text order by horodatage desc limit 1;
  if v_auteur = auth.uid() then raise exception 'Une autre personne que l''auteur de la modification doit la valider.' using errcode = '42501'; end if;
  update public.grilles_credit set valide_conformite = true, date_effet = current_date, updated_at = now() where id = p_id and not valide_conformite;
  if not found then raise exception 'Grille introuvable ou déjà validée.' using errcode = 'P0002'; end if;
  insert into public.journal_audit (acteur_id, acteur_type, action, objet_type, objet_id, avant, apres, motif) values (auth.uid(), 'backoffice', 'GRILLE_CREDIT_VALIDEE', 'grilles_credit', p_id::text, null, null, null);
end $$;

create or replace function public.gmb_bo_formule_prix(p_code text, p_prix numeric, p_motif text)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare f record;
begin
  if not gmb_prive.droit_bo('ADM-03', array['V', 'A']) then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
  if length(trim(coalesce(p_motif, ''))) < 5 then raise exception 'Indiquez le motif de la modification.' using errcode = '22023'; end if;
  if p_prix is null or p_prix < 0 then raise exception 'Indiquez un prix positif ou nul.' using errcode = '22023'; end if;
  select * into f from public.formules where code = p_code for update;
  if not found then raise exception 'Formule inconnue.' using errcode = 'P0002'; end if;
  -- Le prix est toujours prix_mensuel ; prix_ht indique seulement s'il s'entend hors taxes
  insert into public.formules_historique (formule_code, avant, apres, modifie_par)
  values (p_code, jsonb_build_object('prix_mensuel', f.prix_mensuel), jsonb_build_object('prix_mensuel', p_prix), auth.uid());
  update public.formules set prix_mensuel = p_prix where code = p_code;
  insert into public.journal_audit (acteur_id, acteur_type, action, objet_type, objet_id, avant, apres, motif) values (auth.uid(), 'backoffice', 'FORMULE_PRIX', 'formules', p_code, jsonb_build_object('prix_mensuel', f.prix_mensuel), jsonb_build_object('prix_mensuel', p_prix), trim(p_motif));
end $$;

create or replace function public.gmb_bo_taux_usure_ajouter(p_categorie text, p_taux numeric, p_du date, p_au date, p_source text default null)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if not gmb_prive.droit_bo('ADM-03', array['V', 'A']) then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
  if p_taux is null or p_taux <= 0 then raise exception 'Indiquez le taux publié.' using errcode = '22023'; end if;
  if p_du is null or p_au is null or p_du > p_au then raise exception 'Indiquez une période valable.' using errcode = '22023'; end if;
  begin
    insert into public.taux_usure (categorie, taux, valable_du, valable_au, source) values (trim(p_categorie), p_taux, p_du, p_au, nullif(trim(coalesce(p_source, '')), ''));
  exception when unique_violation then
    raise exception 'Un taux est déjà enregistré pour cette catégorie à cette date.' using errcode = '23505';
  end;
  insert into public.journal_audit (acteur_id, acteur_type, action, objet_type, objet_id, avant, apres, motif) values (auth.uid(), 'backoffice', 'TAUX_USURE_AJOUTE', 'taux_usure', trim(p_categorie), null, jsonb_build_object('taux', p_taux, 'du', p_du, 'au', p_au), p_source);
end $$;

-- =============================================================================
-- 21. AUTHENTIFICATION FORTE DES PAIEMENTS (DSP2, lot E1)
-- =============================================================================

-- Code secret du client connecté, saisi sur une grille produite pour SON identifiant :
-- mêmes vérifications, compteurs d'échecs et blocages qu'à la connexion.
create or replace function gmb_prive.sca_verifier(p_grille uuid, p_positions int[])
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_identifiant text; v_grille text; r jsonb;
begin
  select identifiant into v_identifiant from public.clients where auth_user_id = auth.uid() and statut in ('actif', 'inactif');
  if v_identifiant is null then raise exception 'Connexion à l''Espace client requise.' using errcode = '42501'; end if;
  select identifiant into v_grille from gmb_prive.grilles_clavier where id = p_grille;
  if v_grille is distinct from v_identifiant then return jsonb_build_object('statut', 'grille_expiree'); end if;
  r := public.gmb_clavier_verifier(p_grille, p_positions);
  if r ->> 'statut' = 'ok' and (r ->> 'auth_user_id')::uuid is distinct from auth.uid() then
    raise exception 'Authentification refusée.' using errcode = '42501';
  end if;
  return r;
end $$;

-- Validation d'un virement : code secret obligatoire, lié à ce virement (montant et bénéficiaire affichés avant la saisie)
drop function if exists public.gmb_virement_valider(uuid);
create or replace function public.gmb_virement_valider(p_virement uuid, p_grille uuid, p_positions int[])
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v record; r jsonb;
begin
  select * into v from public.virements where id = p_virement;
  if not found or not gmb_prive.compte_accessible(v.compte_id) then
    raise exception 'Virement introuvable.' using errcode = '42501';
  end if;
  if v.statut <> 'a_valider' then
    raise exception 'Ce virement n''est pas à valider.' using errcode = '55000';
  end if;
  r := gmb_prive.sca_verifier(p_grille, p_positions);
  if r ->> 'statut' <> 'ok' then return r; end if;
  update public.virements set statut = 'valide', sca_le = now() where id = p_virement;
  if v.type in ('instantane', 'standard') and v.date_execution <= current_date then
    return gmb_prive.executer_virement(p_virement);
  end if;
  return jsonb_build_object('statut', 'valide', 'date_execution', v.date_execution);
end $$;

-- Ajout d'un bénéficiaire de confiance : code secret obligatoire (RTS, article 13) ;
-- la vérification du nom (VOP) et les plafonds d'origine sont conservés.
create or replace function gmb_prive.beneficiaire_creer(p_nom text, p_iban text, p_utiliser_nom_verifie boolean default false, p_entreprise uuid default null)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare r jsonb; v_id uuid; v_client uuid := gmb_prive.client_courant(); v_plafond numeric; v_heures int; v_resultat text;
  v_saisie text := upper(replace(coalesce(p_iban, ''), ' ', '')); v_interne boolean;
begin
  if v_client is null then
    raise exception 'Connexion requise.' using errcode = '42501';
  end if;
  if p_entreprise is not null and coalesce(gmb_prive.role_entreprise(p_entreprise), '') not in ('administrateur', 'responsable_financier', 'comptable') then
    raise exception 'Votre rôle ne permet pas d''ajouter un bénéficiaire.' using errcode = '42501';
  end if;
  r := public.gmb_vop_verifier(p_nom, v_saisie);
  if r ->> 'resultat' = 'iban_invalide' then
    raise exception '%', r ->> 'message' using errcode = '22023';
  end if;
  v_interne := v_saisie ~ '^[0-9]{11}$';
  v_resultat := case when p_utiliser_nom_verifie and r ? 'nom' then 'correspondance' else r ->> 'resultat' end;
  select coalesce(max(valeur) filter (where cle = 'nouveau_beneficiaire_plafond'), 1000),
         coalesce(max(valeur) filter (where cle = 'nouveau_beneficiaire_heures'), 72)::int
    into v_plafond, v_heures from public.parametres_securite;
  insert into public.beneficiaires (client_id, entreprise_id, nom, nom_verifie, iban, numero_compte, vop_resultat, plafond_temporaire, plafond_temporaire_jusqu)
  values (case when p_entreprise is null then v_client end, p_entreprise,
          case when p_utiliser_nom_verifie and r ? 'nom' then r ->> 'nom' else p_nom end, r ->> 'nom',
          case when v_interne then null else v_saisie end, case when v_interne then v_saisie end,
          v_resultat, v_plafond, now() + make_interval(hours => v_heures))
  returning id into v_id;
  perform gmb_prive.notifier(v_client, null, 'Nouveau bénéficiaire ajouté',
    format('%s a été ajouté à vos bénéficiaires. Si ce n''était pas vous, contactez-nous immédiatement.', coalesce(r ->> 'nom', p_nom)),
    null, 'push', 'MSG-BENEF-01');
  return jsonb_build_object('beneficiaire', v_id) || r;
end $$;
revoke all on function gmb_prive.beneficiaire_creer(text, text, boolean, uuid) from public, anon, authenticated;
drop function if exists public.gmb_beneficiaire_ajouter(text, text, boolean, uuid);
create or replace function public.gmb_beneficiaire_ajouter(p_nom text, p_iban text, p_grille uuid, p_positions int[], p_utiliser_nom_verifie boolean default false, p_entreprise uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r jsonb;
begin
  r := gmb_prive.sca_verifier(p_grille, p_positions);
  if r ->> 'statut' <> 'ok' then return r; end if;
  return gmb_prive.beneficiaire_creer(p_nom, p_iban, p_utiliser_nom_verifie, p_entreprise);
end $$;

-- =============================================================================
-- 22. ÉPARGNE ET EXÉCUTION DES PROGRAMMÉS (lot E1b)
-- =============================================================================

-- Virement entre deux comptes du même titulaire (courant et Livret) : exécution immédiate.
-- Exempté d'authentification forte (DSP2, RTS article 15 : comptes du même titulaire).
create or replace function gmb_prive.transfert_interne(p_depuis uuid, p_vers uuid, p_montant numeric, p_libelle text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare s record; c record;
begin
  if p_montant is null or p_montant <= 0 then raise exception 'Indiquez un montant positif.' using errcode = '22023'; end if;
  if p_depuis = p_vers then raise exception 'Choisissez deux comptes différents.' using errcode = '22023'; end if;
  select * into s from public.comptes where id = p_depuis for update;
  select * into c from public.comptes where id = p_vers for update;
  if s.id is null or c.id is null or s.client_id is null or s.client_id is distinct from c.client_id or s.statut <> 'actif' or c.statut <> 'actif'
     or s.type not in ('courant', 'livret') or c.type not in ('courant', 'livret') then
    raise exception 'Ces deux comptes ne permettent pas ce virement.' using errcode = '22023';
  end if;
  if s.solde < p_montant then
    raise exception 'Votre solde ne permet pas ce virement. Il vous manque % €.', gmb_prive.euros(p_montant - s.solde) using errcode = '22023';
  end if;
  if c.plafond is not null and c.solde + p_montant > c.plafond then
    raise exception 'Le plafond de ce compte est de % € : vous pouvez y verser au plus % €.', gmb_prive.euros(c.plafond), gmb_prive.euros(greatest(c.plafond - c.solde, 0)) using errcode = '22023';
  end if;
  insert into public.operations (compte_id, type, libelle, montant, categorie_code)
  values (p_depuis, 'interne', coalesce(p_libelle, 'Virement vers ' || coalesce(c.libelle, 'votre compte')), -p_montant, 'epargne'),
         (p_vers, 'interne', coalesce(p_libelle, 'Virement depuis ' || coalesce(s.libelle, 'votre compte')), p_montant, 'epargne');
  return jsonb_build_object('statut', 'execute', 'montant', p_montant);
end $$;

create or replace function public.gmb_virement_interne(p_depuis uuid, p_vers uuid, p_montant numeric, p_libelle text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
begin
  if (select client_id from public.comptes where id = p_depuis) is distinct from gmb_prive.client_courant() then
    raise exception 'Compte introuvable.' using errcode = '42501';
  end if;
  return gmb_prive.transfert_interne(p_depuis, p_vers, p_montant, nullif(trim(coalesce(p_libelle, '')), ''));
end $$;

-- Épargne programmée : virement régulier du compte courant vers le Livret (ou l'inverse)
create table if not exists public.epargnes_programmees (
  id               uuid primary key default gen_random_uuid(),
  client_id        uuid not null references public.clients(id) on delete cascade,
  compte_source    uuid not null references public.comptes(id),
  compte_cible     uuid not null references public.comptes(id),
  montant          numeric(12,2) not null check (montant > 0),
  frequence        text not null check (frequence in ('hebdomadaire', 'mensuelle', 'trimestrielle')),
  prochaine_date   date not null,
  actif            boolean not null default true,
  dernier_resultat text,
  derniere_execution date,
  created_at       timestamptz not null default now()
);
comment on table public.epargnes_programmees is 'GMB : épargne programmée (virement régulier entre deux comptes du même titulaire).';

create or replace function public.gmb_epargne_programmer(p_source uuid, p_cible uuid, p_montant numeric, p_frequence text, p_date date)
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare v_client uuid := gmb_prive.client_courant(); v_id uuid;
begin
  if v_client is null then raise exception 'Connexion requise.' using errcode = '42501'; end if;
  if (select count(*) from public.comptes where id in (p_source, p_cible) and client_id = v_client and statut = 'actif' and type in ('courant', 'livret')) <> 2 or p_source = p_cible then
    raise exception 'Choisissez deux de vos comptes : compte courant et Livret.' using errcode = '22023';
  end if;
  if p_montant is null or p_montant <= 0 then raise exception 'Indiquez un montant positif.' using errcode = '22023'; end if;
  if p_frequence not in ('hebdomadaire', 'mensuelle', 'trimestrielle') then raise exception 'Fréquence inconnue.' using errcode = '22023'; end if;
  if p_date is null or p_date < current_date then raise exception 'Choisissez une date de début à venir.' using errcode = '22023'; end if;
  insert into public.epargnes_programmees (client_id, compte_source, compte_cible, montant, frequence, prochaine_date)
  values (v_client, p_source, p_cible, p_montant, p_frequence, p_date) returning id into v_id;
  return v_id;
end $$;

create or replace function public.gmb_epargne_programmee_arreter(p_id uuid)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  update public.epargnes_programmees set actif = false where id = p_id and client_id = gmb_prive.client_courant() and actif;
  if not found then raise exception 'Épargne programmée introuvable ou déjà arrêtée.' using errcode = 'P0002'; end if;
end $$;

-- Clôture d'un coffre : son solde revient sur le compte courant
create or replace function public.gmb_coffre_cloturer(p_coffre uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare k record; v_solde numeric;
begin
  select * into k from public.coffres where id = p_coffre and client_id = gmb_prive.client_courant() and statut <> 'clos' for update;
  if not found then raise exception 'Coffre introuvable ou déjà clos.' using errcode = 'P0002'; end if;
  select solde into v_solde from public.comptes where id = k.compte_id;
  if v_solde > 0 then perform public.gmb_coffre_mouvement(p_coffre, -v_solde); end if;
  update public.coffres set statut = 'clos', updated_at = now() where id = p_coffre;
  update public.comptes set statut = 'cloture', updated_at = now() where id = k.compte_id;
  return jsonb_build_object('statut', 'clos', 'rendu', coalesce(v_solde, 0));
end $$;

-- Exécution quotidienne (serveur uniquement, planifiée par pg_cron) :
-- virements différés et permanents arrivés à échéance, puis épargne programmée.
create or replace function public.gmb_executer_programmes(p_jour date default current_date)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v record; e record; r jsonb; n_v int := 0; n_e int := 0; n_echecs int := 0;
        pas interval;
begin
  for v in select * from public.virements where statut = 'valide' and date_execution <= p_jour order by date_execution, created_at for update skip locked loop
    r := gmb_prive.executer_virement(v.id);
    n_v := n_v + 1;
    if r ->> 'statut' = 'rejete' then n_echecs := n_echecs + 1; end if;
    if v.type = 'permanent' and v.frequence is not null then
      pas := case v.frequence when 'hebdomadaire' then interval '7 days' when 'mensuelle' then interval '1 month' when 'trimestrielle' then interval '3 months' else interval '1 year' end;
      insert into public.virements (compte_id, beneficiaire_id, montant, devise, motif, type, date_execution, frequence, statut, vop_resultat, vop_choix, sca_le, cree_par)
      values (v.compte_id, v.beneficiaire_id, v.montant, v.devise, v.motif, 'permanent', (v.date_execution + pas)::date, v.frequence, 'valide', v.vop_resultat, v.vop_choix, v.sca_le, v.cree_par);
    end if;
  end loop;
  for e in select * from public.epargnes_programmees where actif and prochaine_date <= p_jour order by prochaine_date for update skip locked loop
    pas := case e.frequence when 'hebdomadaire' then interval '7 days' when 'mensuelle' then interval '1 month' else interval '3 months' end;
    begin
      perform gmb_prive.transfert_interne(e.compte_source, e.compte_cible, e.montant, 'Épargne programmée');
      update public.epargnes_programmees set dernier_resultat = 'effectuée', derniere_execution = p_jour, prochaine_date = (prochaine_date + pas)::date where id = e.id;
    exception when others then
      n_echecs := n_echecs + 1;
      update public.epargnes_programmees set dernier_resultat = sqlerrm, derniere_execution = p_jour, prochaine_date = (prochaine_date + pas)::date where id = e.id;
      perform gmb_prive.notifier(e.client_id, null, 'Épargne programmée non effectuée', sqlerrm, null, 'in_app', null);
    end;
    n_e := n_e + 1;
  end loop;
  return jsonb_build_object('virements', n_v, 'epargnes', n_e, 'echecs', n_echecs);
end $$;

-- Règles d'accès (production) : tables ajoutées aux lots 2, C et E1b
drop policy if exists demandeur on public.dossier_entreprises;
create policy demandeur on public.dossier_entreprises for select to authenticated using (gmb_prive.dossier_du_demandeur(dossier_id));
drop policy if exists demandeur on public.dossier_jeunes;
create policy demandeur on public.dossier_jeunes for select to authenticated using (gmb_prive.dossier_du_demandeur(dossier_id));
drop policy if exists titulaire on public.epargnes_programmees;
create policy titulaire on public.epargnes_programmees for select to authenticated using (client_id = gmb_prive.client_courant());
drop policy if exists lecture_backoffice on public.dossier_entreprises;
create policy lecture_backoffice on public.dossier_entreprises for select to authenticated using (gmb_prive.bo_lecture('ADM-04') or gmb_prive.bo_lecture('ADM-11'));
drop policy if exists lecture_backoffice on public.dossier_jeunes;
create policy lecture_backoffice on public.dossier_jeunes for select to authenticated using (gmb_prive.bo_lecture('ADM-04'));
drop policy if exists lecture_backoffice on public.epargnes_programmees;
create policy lecture_backoffice on public.epargnes_programmees for select to authenticated using (gmb_prive.bo_lecture('ADM-07'));

-- =============================================================================
-- 23. CRÉDIT : PRÉLÈVEMENT DES ÉCHÉANCES, REMBOURSEMENT ANTICIPÉ (lot E1b)
-- =============================================================================

-- Déblocage d'un dossier de crédit : fonds versés sur le compte GerMoonBank du demandeur
create or replace function public.gmb_bo_credit_debloquer(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare d record; v_compte uuid; v_credit uuid; dc record; v_client uuid;
begin
  if not gmb_prive.bo_decision('ADM-08') then
    raise exception 'Droits insuffisants.' using errcode = '42501';
  end if;
  if exists (select 1 from public.dossiers where id = p_id and type = 'credit') then
    select ds.id, ds.reference, ds.etat, ds.personne_id, x.montant, x.duree_mois, x.taux_debiteur, x.taeg, x.mensualite, x.deblocage_possible_le
      into dc from public.dossiers ds join public.dossier_credit x on x.dossier_id = ds.id where ds.id = p_id for update of ds;
    if dc.etat <> 'delai_legal' or current_date < dc.deblocage_possible_le::date then
      raise exception 'Versement impossible avant le 8e jour suivant l''acceptation.' using errcode = '55000';
    end if;
    -- Les fonds sont versés sur le compte GerMoonBank du demandeur et les échéances y sont prélevées
    select c.id into v_client from public.clients c join public.personnes q on q.id = c.personne_id join public.personnes p on p.id = dc.personne_id
     where c.statut = 'actif' and lower(q.email) = lower(p.email) and q.date_naissance = p.date_naissance and upper(q.nom_naissance) = upper(p.nom_naissance)
     order by c.created_at limit 1;
    if v_client is null then
      raise exception 'Le demandeur ne détient pas de compte GerMoonBank : les fonds ne peuvent pas lui être versés, ni les échéances prélevées. Il doit d''abord ouvrir un compte.' using errcode = '55000';
    end if;
    select id into v_compte from public.comptes where client_id = v_client and type = 'courant' and statut = 'actif' order by ouvert_le limit 1;
    if v_compte is null then raise exception 'Le compte courant du demandeur n''est pas actif.' using errcode = '55000'; end if;
    update public.dossiers set etat = 'acceptee' where id = p_id;
    update public.dossier_credit set fonds_debloques_le = now() where dossier_id = p_id;
    update public.dossiers set etat = 'fonds_debloques' where id = p_id;
    insert into public.credits (client_id, compte_id, montant, duree_mois, taux_debiteur, taeg, mensualite, debut, capital_restant)
    values (v_client, v_compte, dc.montant, dc.duree_mois, dc.taux_debiteur, dc.taeg, dc.mensualite, current_date, dc.montant) returning id into v_credit;
    perform gmb_prive.generer_echeancier(v_credit);
    insert into public.operations (compte_id, type, libelle, montant, categorie_code) values (v_compte, 'credit', 'Prêt personnel ' || dc.reference, dc.montant, 'transferts');
    return jsonb_build_object('etat', 'fonds_debloques', 'credit', v_credit);
  end if;
  select * into d from public.demandes where id = p_id and type = 'pret_personnel' for update;
  if not found or d.etat <> 'delai_legal' or current_date < d.deblocage_possible_le::date then
    raise exception 'Versement impossible avant le 8e jour suivant l''acceptation.' using errcode = '55000';
  end if;
  select id into v_compte from public.comptes where client_id = d.client_id and type = 'courant' and statut = 'actif' order by ouvert_le limit 1;
  update public.demandes set etat = 'acceptee' where id = p_id;
  update public.demandes set etat = 'fonds_debloques', fonds_debloques_le = now() where id = p_id;
  insert into public.credits (client_id, demande_id, compte_id, montant, duree_mois, taux_debiteur, taeg, mensualite, debut, capital_restant)
  values (d.client_id, d.id, v_compte, d.montant, d.duree_mois, d.taux_debiteur, d.taeg, d.mensualite, current_date, d.montant)
  returning id into v_credit;
  perform gmb_prive.generer_echeancier(v_credit);
  insert into public.operations (compte_id, type, libelle, montant, categorie_code)
  values (v_compte, 'credit', 'Prêt personnel ' || d.reference, d.montant, 'transferts');
  return jsonb_build_object('etat', 'fonds_debloques', 'credit', v_credit);
end $$;

-- Remboursements anticipés (historique ; sert aussi à l'exonération de 10 000 € sur 12 mois)
create table if not exists public.credit_remboursements_anticipes (
  id          uuid primary key default gen_random_uuid(),
  credit_id   uuid not null references public.credits(id) on delete cascade,
  montant     numeric(12,2) not null check (montant > 0),
  indemnite   numeric(12,2) not null default 0 check (indemnite >= 0),
  type        text not null check (type in ('partiel', 'total')),
  created_at  timestamptz not null default now()
);
comment on table public.credit_remboursements_anticipes is 'GMB : remboursements anticipés d''un prêt (montant, indemnité).';

-- Prélèvement des échéances arrivées à date (serveur uniquement, planifié chaque jour) :
-- payée si le solde suffit, sinon impayée et représentée chaque jour, client prévenu.
create or replace function public.gmb_prelever_echeances(p_jour date default current_date)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e record; c record; k record; n_payees int := 0; n_impayees int := 0;
begin
  for e in select * from public.credit_echeances where statut in ('a_venir', 'impayee') and date_echeance <= p_jour order by credit_id, numero for update skip locked loop
    select * into c from public.credits where id = e.credit_id for update;
    if c.statut = 'rembourse' then continue; end if;
    select * into k from public.comptes where id = c.compte_id for update;
    if k.statut = 'actif' and k.solde >= e.montant then
      insert into public.operations (compte_id, type, libelle, montant, categorie_code)
      values (c.compte_id, 'credit', format('Échéance %s/%s du prêt', e.numero, c.duree_mois), -e.montant, 'transferts');
      update public.credit_echeances set statut = 'payee' where credit_id = e.credit_id and numero = e.numero;
      update public.credits set capital_restant = e.capital_restant,
             statut = case when not exists (select 1 from public.credit_echeances where credit_id = e.credit_id and statut <> 'payee') then 'rembourse'
                           when exists (select 1 from public.credit_echeances where credit_id = e.credit_id and statut = 'impayee') then 'impaye' else 'en_cours' end
       where id = e.credit_id;
      n_payees := n_payees + 1;
    else
      if e.statut = 'a_venir' then
        update public.credit_echeances set statut = 'impayee' where credit_id = e.credit_id and numero = e.numero;
        perform gmb_prive.notifier(c.client_id, null, 'Échéance de prêt impayée',
          format('L’échéance %s/%s de votre prêt (%s €) n’a pas pu être prélevée faute de solde suffisant. Elle sera représentée chaque jour : approvisionnez votre compte.', e.numero, c.duree_mois, gmb_prive.euros(e.montant)), null, 'in_app', null);
      end if;
      update public.credits set statut = 'impaye' where id = e.credit_id;
      n_impayees := n_impayees + 1;
    end if;
  end loop;
  return jsonb_build_object('payees', n_payees, 'impayees', n_impayees);
end $$;

-- Remboursement anticipé : calcul (Code de la consommation, article L312-34)
--   indemnité de 1 % du montant remboursé si plus d'un an reste à courir, 0,5 % sinon,
--   sans dépasser les intérêts restant dus ; aucune indemnité si les remboursements
--   anticipés des 12 derniers mois, celui-ci compris, ne dépassent pas 10 000 €.
create or replace function public.gmb_credit_anticipation(p_credit uuid, p_montant numeric default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare c record; v_montant numeric; v_restantes int; v_fin date; v_interets numeric; v_douze numeric; v_taux numeric; v_ind numeric; v_type text;
begin
  select * into c from public.credits where id = p_credit and client_id = gmb_prive.client_courant();
  if not found then raise exception 'Prêt introuvable.' using errcode = '42501'; end if;
  if c.statut = 'rembourse' or c.capital_restant <= 0 then raise exception 'Ce prêt est entièrement remboursé.' using errcode = '55000'; end if;
  if exists (select 1 from public.credit_echeances where credit_id = p_credit and statut = 'impayee') then
    raise exception 'Régularisez d''abord vos échéances impayées.' using errcode = '55000';
  end if;
  v_montant := least(coalesce(p_montant, c.capital_restant), c.capital_restant);
  if v_montant <= 0 then raise exception 'Indiquez un montant positif.' using errcode = '22023'; end if;
  v_type := case when v_montant >= c.capital_restant then 'total' else 'partiel' end;
  select count(*), max(date_echeance), coalesce(sum(interets), 0) into v_restantes, v_fin, v_interets from public.credit_echeances where credit_id = p_credit and statut = 'a_venir';
  select coalesce(sum(r.montant), 0) into v_douze from public.credit_remboursements_anticipes r join public.credits k on k.id = r.credit_id
   where k.client_id = c.client_id and r.created_at > now() - interval '12 months';
  v_taux := case when v_fin is not null and v_fin > current_date + 365 then 0.01 else 0.005 end;
  v_ind := case when v_douze + v_montant <= 10000 then 0 else least(round(v_montant * v_taux, 2), v_interets) end;
  return jsonb_build_object('type', v_type, 'capital_restant', c.capital_restant, 'montant', v_montant, 'indemnite', v_ind, 'total', v_montant + v_ind,
    'taux_indemnite', v_taux * 100, 'exonere', v_douze + v_montant <= 10000, 'echeances_restantes', v_restantes, 'fin_prevue', v_fin,
    'nouvelle_mensualite', case when v_type = 'partiel' and v_restantes > 0 then gmb_prive.mensualite(c.capital_restant - v_montant, c.taux_debiteur, v_restantes) end,
    'mensualite_actuelle', c.mensualite);
end $$;

-- Remboursement anticipé : exécution, confirmée par le code secret
create or replace function public.gmb_credit_rembourser_par_anticipation(p_credit uuid, p_montant numeric, p_grille uuid, p_positions int[])
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r jsonb; a jsonb; c record; k record; v_reste numeric; v_mens numeric; v_int numeric; v_cap numeric; e record; v_crd numeric; v_n int := 0; v_total int;
begin
  a := public.gmb_credit_anticipation(p_credit, p_montant);
  r := gmb_prive.sca_verifier(p_grille, p_positions);
  if r ->> 'statut' <> 'ok' then return r; end if;
  select * into c from public.credits where id = p_credit for update;
  select * into k from public.comptes where id = c.compte_id for update;
  if k.solde < (a ->> 'total')::numeric then
    raise exception 'Votre solde ne permet pas ce remboursement. Il vous manque % €.', gmb_prive.euros((a ->> 'total')::numeric - k.solde) using errcode = '22023';
  end if;
  insert into public.operations (compte_id, type, libelle, montant, categorie_code)
  values (c.compte_id, 'credit', case when a ->> 'type' = 'total' then 'Remboursement anticipé total du prêt' else 'Remboursement anticipé partiel du prêt' end
          || case when (a ->> 'indemnite')::numeric > 0 then format(' (dont indemnité %s €)', gmb_prive.euros((a ->> 'indemnite')::numeric)) else '' end,
          -(a ->> 'total')::numeric, 'transferts');
  insert into public.credit_remboursements_anticipes (credit_id, montant, indemnite, type) values (p_credit, (a ->> 'montant')::numeric, (a ->> 'indemnite')::numeric, a ->> 'type');
  v_reste := c.capital_restant - (a ->> 'montant')::numeric;
  if a ->> 'type' = 'total' then
    delete from public.credit_echeances where credit_id = p_credit and statut = 'a_venir';
    update public.credits set capital_restant = 0, statut = 'rembourse' where id = p_credit;
  else
    -- Mêmes dates, même nombre d'échéances, mensualité réduite
    select count(*) into v_total from public.credit_echeances where credit_id = p_credit and statut = 'a_venir';
    v_mens := gmb_prive.mensualite(v_reste, c.taux_debiteur, v_total);
    v_crd := v_reste;
    for e in select * from public.credit_echeances where credit_id = p_credit and statut = 'a_venir' order by numero for update loop
      v_n := v_n + 1;
      v_int := round(v_crd * c.taux_debiteur / 1200, 2);
      v_cap := case when v_n = v_total then v_crd else v_mens - v_int end;
      v_crd := v_crd - v_cap;
      update public.credit_echeances set capital = v_cap, interets = v_int, montant = v_cap + v_int, capital_restant = v_crd where credit_id = p_credit and numero = e.numero;
    end loop;
    update public.credits set capital_restant = v_reste, mensualite = v_mens where id = p_credit;
  end if;
  perform gmb_prive.notifier(c.client_id, null, 'Remboursement anticipé effectué',
    format('Vous avez remboursé %s € par anticipation%s.', gmb_prive.euros((a ->> 'montant')::numeric), case when a ->> 'type' = 'total' then ' : votre prêt est soldé' else format(' : votre nouvelle mensualité est de %s €', gmb_prive.euros(v_mens)) end), null, 'in_app', null);
  return a || jsonb_build_object('statut', 'ok', 'nouvelle_mensualite', v_mens);
end $$;

drop policy if exists titulaire on public.credit_remboursements_anticipes;
create policy titulaire on public.credit_remboursements_anticipes for select to authenticated using (exists (select 1 from public.credits k where k.id = credit_id and k.client_id = gmb_prive.client_courant()));
drop policy if exists lecture_backoffice on public.credit_remboursements_anticipes;
create policy lecture_backoffice on public.credit_remboursements_anticipes for select to authenticated using (gmb_prive.bo_lecture('ADM-08'));

-- =============================================================================
-- 24. DOSSIER COMBINÉ : OUVERTURE DE COMPTE ET DEMANDE DE PRÊT (lot E2)
-- =============================================================================

create or replace function public.gmb_dossier_credit_projet(p_dossier uuid, p_montant numeric, p_duree int, p_objet text default 'autre',
                                                            p_revenus numeric default null, p_charges numeric default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare s jsonb;
begin
  if not gmb_prive.dossier_du_demandeur(p_dossier) or not exists (select 1 from public.dossiers where id = p_dossier and (type = 'credit' or (type = 'ouverture' and segment = 'particulier'))) then
    raise exception 'Dossier de crédit introuvable.' using errcode = '42501';
  end if;
  if (select etat from public.dossiers where id = p_dossier) not in ('brouillon', 'incomplet') then
    raise exception 'Ce dossier ne peut plus être modifié.' using errcode = '55000';
  end if;
  -- Ouverture avec prêt : le justificatif de revenus s'ajoute aux pièces
  insert into public.dossier_pieces (dossier_id, type)
  select p_dossier, 'justificatif_revenus' where not exists (select 1 from public.dossier_pieces where dossier_id = p_dossier and type = 'justificatif_revenus');
  s := public.gmb_simuler_credit(p_montant, p_duree, p_objet);
  if not (s ->> 'disponible')::boolean then
    raise exception '%', s ->> 'message' using errcode = '22023';
  end if;
  insert into public.dossier_credit (dossier_id, objet, montant, duree_mois, revenus_mensuels, charges_mensuelles,
                                     taux_debiteur, taeg, mensualite, cout_total, montant_total_du)
  values (p_dossier, coalesce(p_objet, 'autre'), p_montant, p_duree, p_revenus, p_charges,
          (s ->> 'taux_debiteur')::numeric, (s ->> 'taeg')::numeric, (s ->> 'mensualite')::numeric,
          (s ->> 'cout_total')::numeric, (s ->> 'montant_total_du')::numeric)
  on conflict (dossier_id) do update set objet = excluded.objet, montant = excluded.montant, duree_mois = excluded.duree_mois,
     revenus_mensuels = excluded.revenus_mensuels, charges_mensuelles = excluded.charges_mensuelles,
     taux_debiteur = excluded.taux_debiteur, taeg = excluded.taeg, mensualite = excluded.mensualite,
     cout_total = excluded.cout_total, montant_total_du = excluded.montant_total_du;
  return s;
end $$;

create or replace function public.gmb_dossier_deposer(p_dossier uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare d record; v_manquantes int;
begin
  if not gmb_prive.dossier_du_demandeur(p_dossier) then
    raise exception 'Dossier introuvable.' using errcode = '42501';
  end if;
  select * into d from public.dossiers where id = p_dossier for update;
  if d.etat <> 'brouillon' then
    raise exception 'Ce dossier est déjà déposé.' using errcode = '55000';
  end if;
  select count(*) into v_manquantes from public.dossier_pieces where dossier_id = p_dossier and statut in ('attendue', 'refusee');
  if v_manquantes > 0 then
    raise exception 'Il manque % pièce(s) à votre dossier.', v_manquantes using errcode = '55000';
  end if;
  if not exists (select 1 from public.consentements where auth_user_id = auth.uid() and type = 'cgu' and accorde)
     or not exists (select 1 from public.consentements where auth_user_id = auth.uid() and type = 'confidentialite' and accorde) then
    raise exception 'Merci d''accepter les conditions générales et la politique de confidentialité.' using errcode = '55000';
  end if;
  if d.type = 'ouverture' and d.segment in ('pro', 'business') and not exists (select 1 from public.dossier_entreprises where dossier_id = p_dossier) then
    raise exception 'Renseignez les informations de votre entreprise.' using errcode = '55000';
  end if;
  if d.type = 'ouverture' and d.segment = 'jeunes' and not exists (select 1 from public.dossier_jeunes where dossier_id = p_dossier) then
    raise exception 'Renseignez les informations de votre enfant.' using errcode = '55000';
  end if;
  if d.type = 'ouverture' and not exists (select 1 from public.premiers_versements where dossier_id = p_dossier) then
    raise exception 'Le premier versement est nécessaire pour déposer votre dossier.' using errcode = '55000';
  end if;
  if (d.type = 'credit' or exists (select 1 from public.dossier_credit where dossier_id = p_dossier)) and not exists (select 1 from public.dossier_credit where dossier_id = p_dossier and consentement_ficp) then
    raise exception 'Votre accord pour la consultation du FICP est nécessaire.' using errcode = '55000';
  end if;
  update public.dossiers
     set etat = case when d.type = 'credit' then 'demande_deposee' else 'depose' end,
         depose_le = now(), sla_echeance = gmb_prive.ajouter_jours_ouvres(now(), 2), etape_tunnel = 11
   where id = p_dossier;
  return jsonb_build_object('reference', d.reference, 'etat', case when d.type = 'credit' then 'demande_deposee' else 'depose' end);
end $$;

-- GerMoonBank · installation de la base, partie 6 sur 8
-- Exécutez les parties dans l'ordre, chacune dans une requête vide du SQL Editor.
-- Contenu : 03_fonctions
create or replace function gmb_prive.ouvrir_compte(p_dossier uuid)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare d record; f record; v record; e record; j record; v_client uuid; v_courant uuid; v_entreprise uuid; v_personne_enfant uuid; v_enfant uuid; v_compte_jeune uuid; v_demande uuid;
begin
  select * into d from public.dossiers where id = p_dossier;
  if d.etat = 'compte_ouvert' or exists (select 1 from public.clients where dossier_origine_id = p_dossier) then
    raise exception 'Le compte de ce dossier est déjà ouvert.' using errcode = '55000';
  end if;
  select * into f from public.formules where code = coalesce(d.formule_code, 'luna');
  select * into v from public.premiers_versements where dossier_id = p_dossier;
  if d.type = 'ouverture' and (not found or v.statut <> 'recu') then
    raise exception 'Le premier versement n''a pas encore été reçu : ouverture impossible.' using errcode = '55000';
  end if;
  insert into public.clients (personne_id, identifiant, segment, formule_code, dossier_origine_id, ficoba_declare_le)
  values (d.personne_id, gmb_prive.nouvel_identifiant(), case when d.segment = 'jeunes' then 'particulier' else d.segment end, f.code, p_dossier, now())
  returning id into v_client;
  if d.segment in ('pro', 'business') then
    select * into e from public.dossier_entreprises where dossier_id = p_dossier;
    if not found then
      raise exception 'Les informations de l''entreprise manquent : ouverture impossible.' using errcode = '55000';
    end if;
    if exists (select 1 from public.entreprises where siren = e.siren) then
      raise exception 'Une entreprise portant ce SIREN est déjà cliente.' using errcode = '23505';
    end if;
    insert into public.entreprises (raison_sociale, siren, forme, formule_code, adresse)
    values (e.raison_sociale, e.siren, e.forme_juridique, f.code, e.adresse_siege || ', ' || e.code_postal || ' ' || e.ville)
    returning id into v_entreprise;
    insert into public.entreprise_membres (entreprise_id, client_id, role, statut) values (v_entreprise, v_client, 'administrateur', 'actif');
  end if;
  if d.segment = 'business' then
    insert into public.comptes (entreprise_id, type, libelle, numero)
    values (v_entreprise, 'business', 'Compte Business', gmb_prive.nouveau_numero_compte())
    returning id into v_courant;
  else
    insert into public.comptes (client_id, type, libelle, numero)
    values (v_client, case when d.segment = 'pro' then 'pro' else 'courant' end,
            case when d.segment = 'pro' then 'Compte professionnel' else 'Compte courant' end, gmb_prive.nouveau_numero_compte())
    returning id into v_courant;
  end if;
  if f.taux_livret is not null and d.segment in ('particulier', 'jeunes') then
    insert into public.comptes (client_id, type, libelle, taux, plafond, numero)
    values (v_client, 'livret', 'Livret GMB', f.taux_livret, 100000, gmb_prive.nouveau_numero_compte());
  end if;
  if d.segment = 'jeunes' then
    select * into j from public.dossier_jeunes where dossier_id = p_dossier;
    if not found then
      raise exception 'Les informations de l''enfant manquent : ouverture impossible.' using errcode = '55000';
    end if;
    insert into public.personnes (civilite, nom_naissance, prenoms, date_naissance, lieu_naissance, pays_naissance, nationalite,
                                  adresse_ligne1, adresse_ligne2, code_postal, ville, pays, residence_fiscale)
    select j.civilite, j.nom, j.prenoms, j.date_naissance, j.lieu_naissance, j.pays_naissance, j.nationalite,
           p.adresse_ligne1, p.adresse_ligne2, p.code_postal, p.ville, p.pays, p.residence_fiscale
      from public.personnes p where p.id = d.personne_id
    returning id into v_personne_enfant;
    insert into public.clients (personne_id, identifiant, segment, formule_code)
    values (v_personne_enfant, gmb_prive.nouvel_identifiant(), 'jeunes', 'luna') returning id into v_enfant;
    insert into public.comptes (client_id, type, libelle, numero)
    values (v_enfant, 'jeune', 'Compte Jeunes', gmb_prive.nouveau_numero_compte()) returning id into v_compte_jeune;
    insert into public.comptes_jeunes (compte_id, jeune_client_id, parent_client_id) values (v_compte_jeune, v_enfant, v_client);
  end if;
  if v.statut = 'recu' then
    insert into public.operations (compte_id, type, libelle, montant, categorie_code)
    values (v_courant, 'versement_initial', 'Premier versement', coalesce(v.montant_recu, v.montant), 'transferts');
    update public.premiers_versements set statut = 'credite', credite_le = now() where dossier_id = p_dossier;
  end if;
  update public.dossiers set etat = 'compte_ouvert', ouvert_le = now() where id = p_dossier;
  -- Dossier combiné : la demande de prêt du nouveau client est créée, à l'étude
  if exists (select 1 from public.dossier_credit where dossier_id = p_dossier) then
    insert into public.demandes (client_id, reference, type, etat, montant, duree_mois, objet, taux_debiteur, taeg, mensualite, cout_total, montant_total_du, donnees)
    select v_client, gmb_prive.reference('CRE'), 'pret_personnel', 'analyse', x.montant, x.duree_mois, x.objet, x.taux_debiteur, x.taeg, x.mensualite, x.cout_total, x.montant_total_du,
           jsonb_build_object('dossier', p_dossier, 'revenus_mensuels', x.revenus_mensuels, 'charges_mensuelles', x.charges_mensuelles, 'consentement_ficp', true)
      from public.dossier_credit x where x.dossier_id = p_dossier
    returning id into v_demande;
    insert into public.demande_evenements (demande_id, etat_avant, etat_apres, libelle_client)
    values (v_demande, null, 'analyse', 'Votre compte est ouvert : votre demande de prêt est à l’étude.');
  end if;
  perform gmb_prive.notifier(v_client, d.demandeur_auth, 'Votre compte est ouvert',
    'Votre identifiant bancaire est disponible dans l''Espace Mon Dossier. Activez ensuite votre accès : un code vous sera envoyé par e-mail.' || case when v_demande is not null then ' Votre demande de prêt est à l''étude : l''offre apparaîtra dans votre Espace client.' else '' end,
    '/mon-dossier/', 'email', 'MSG-COMPTE-OUVERT');
  return v_client;
end $$;

create or replace function public.gmb_bo_credit_offre(p_id uuid, p_taux numeric default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare c record; d record; s jsonb; v_taux numeric; v_mens numeric;
begin
  if not gmb_prive.bo_decision('ADM-08') then
    raise exception 'Droits insuffisants.' using errcode = '42501';
  end if;
  select dc.*, ds.etat into c from public.dossier_credit dc join public.dossiers ds on ds.id = dc.dossier_id where dc.dossier_id = p_id;
  if found then
    if c.etat not in ('analyse', 'incomplet') then
      raise exception 'Le dossier doit être en analyse.' using errcode = '55000';
    end if;
    s := public.gmb_simuler_credit(c.montant, c.duree_mois, c.objet);
    v_taux := coalesce(p_taux, (s ->> 'taux_debiteur')::numeric);
    v_mens := gmb_prive.mensualite(c.montant, v_taux, c.duree_mois);
    if c.revenus_mensuels is not null and c.revenus_mensuels > 0
       and (coalesce(c.charges_mensuelles, 0) + v_mens) / c.revenus_mensuels > 0.35 then
      insert into public.dossier_controles (dossier_id, controle, resultat, details)
      values (p_id, 'solvabilite', 'non_conforme', jsonb_build_object('taux_effort', round((coalesce(c.charges_mensuelles, 0) + v_mens) / c.revenus_mensuels * 100, 1)));
      raise exception 'Taux d''effort supérieur à 35 %% : offre impossible.' using errcode = '55000';
    end if;
    update public.dossier_credit
       set taux_debiteur = v_taux, taeg = gmb_prive.taeg(v_taux), mensualite = v_mens, montant_total_du = v_mens * duree_mois,
           cout_total = v_mens * duree_mois - montant, ficp_consulte_le = now(), offre_emise_le = now()
     where dossier_id = p_id;
    insert into public.dossier_controles (dossier_id, controle, resultat) values (p_id, 'ficp', 'conforme'), (p_id, 'solvabilite', 'conforme');
    update public.dossiers set etat = 'offre_emise' where id = p_id;
    return jsonb_build_object('etat', 'offre_emise', 'mensualite', v_mens, 'taeg', gmb_prive.taeg(v_taux));
  end if;
  select * into d from public.demandes where id = p_id and type = 'pret_personnel' for update;
  if not found or d.etat not in ('demande_deposee', 'analyse', 'incomplet') then
    raise exception 'Demande de prêt introuvable ou déjà traitée.' using errcode = '55000';
  end if;
  v_taux := coalesce(p_taux, d.taux_debiteur);
  v_mens := gmb_prive.mensualite(d.montant, v_taux, d.duree_mois);
    if coalesce((d.donnees ->> 'revenus_mensuels')::numeric, 0) > 0
       and (coalesce((d.donnees ->> 'charges_mensuelles')::numeric, 0) + v_mens) / (d.donnees ->> 'revenus_mensuels')::numeric > 0.35 then
      raise exception 'Taux d''effort supérieur à 35 %% : offre impossible.' using errcode = '55000';
    end if;
  update public.demandes
     set etat = 'offre_emise', taux_debiteur = v_taux, taeg = gmb_prive.taeg(v_taux), mensualite = v_mens,
         montant_total_du = v_mens * duree_mois, cout_total = v_mens * duree_mois - montant, offre_emise_le = now()
   where id = p_id;
  return jsonb_build_object('etat', 'offre_emise', 'mensualite', v_mens, 'taeg', gmb_prive.taeg(v_taux));
end $$;

-- =============================================================================
-- 25. COTISATIONS DES FORMULES (lot E2a)
-- =============================================================================

create table if not exists public.cotisations (
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null references public.clients(id) on delete cascade,
  compte_id     uuid not null references public.comptes(id),
  mois          date not null check (mois = date_trunc('month', mois)::date),
  formule_code  text not null,
  libelle       text not null,
  montant       numeric(10,2) not null check (montant > 0),
  statut        text not null default 'impayee' check (statut in ('prelevee', 'impayee')),
  prelevee_le   timestamptz,
  created_at    timestamptz not null default now(),
  unique (client_id, mois)
);
comment on table public.cotisations is 'GMB : cotisations mensuelles des formules (une par client et par mois).';

-- Prélèvement des cotisations (serveur uniquement, planifié chaque jour) : la cotisation du
-- mois est prélevée une fois, à partir du mois qui suit l'ouverture ; une cotisation impayée
-- est représentée chaque jour, client prévenu au premier échec.
create or replace function public.gmb_prelever_cotisations(p_jour date default current_date)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare c record; k record; z record; v_mois date := date_trunc('month', p_jour)::date; n_p int := 0; n_i int := 0;
begin
  -- 1. Cotisations du mois à créer
  for c in select cl.id, cl.segment, cl.formule_code, f.nom, f.prix_mensuel from public.clients cl join public.formules f on f.code = cl.formule_code
            where cl.statut = 'actif' and f.prix_mensuel > 0 and coalesce(cl.ouvert_le, cl.created_at) < v_mois
              and not exists (select 1 from public.cotisations x where x.client_id = cl.id and x.mois = v_mois) loop
    select k2.* into k from public.comptes k2
     where k2.statut = 'actif' and (k2.client_id = c.id or k2.entreprise_id in (select m.entreprise_id from public.entreprise_membres m where m.client_id = c.id and m.statut = 'actif' and m.role = 'administrateur'))
       and k2.type in ('courant', 'pro', 'business')
     order by case when c.segment in ('pro', 'business') and k2.type in ('pro', 'business') then 0 when k2.type = 'courant' then 1 else 2 end, k2.ouvert_le limit 1;
    if k.id is null then continue; end if;
    insert into public.cotisations (client_id, compte_id, mois, formule_code, libelle, montant)
    values (c.id, k.id, v_mois, c.formule_code, format('Cotisation %s — %s %s', c.nom, (array['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'])[extract(month from v_mois)::int], extract(year from v_mois)::int), c.prix_mensuel);
  end loop;
  -- 2. Prélèvement des cotisations dues (du mois, et impayées des mois précédents)
  for z in select * from public.cotisations where statut = 'impayee' and mois <= v_mois order by mois for update skip locked loop
    select * into k from public.comptes where id = z.compte_id for update;
    if k.statut = 'actif' and k.solde >= z.montant then
      insert into public.operations (compte_id, type, libelle, montant, categorie_code) values (z.compte_id, 'frais', z.libelle, -z.montant, 'frais');
      update public.cotisations set statut = 'prelevee', prelevee_le = now() where id = z.id;
      n_p := n_p + 1;
    else
      if z.created_at::date = p_jour or not exists (select 1 from public.notifications where client_id = z.client_id and titre = 'Cotisation non prélevée' and created_at::date >= z.mois) then
        perform gmb_prive.notifier(z.client_id, null, 'Cotisation non prélevée',
          format('Votre %s (%s €) n’a pas pu être prélevée faute de solde suffisant. Elle sera représentée chaque jour : approvisionnez votre compte.', lower(left(z.libelle, 1)) || substr(z.libelle, 2), gmb_prive.euros(z.montant)), null, 'in_app', null);
      end if;
      n_i := n_i + 1;
    end if;
  end loop;
  return jsonb_build_object('prelevees', n_p, 'impayees', n_i);
end $$;

drop policy if exists titulaire on public.cotisations;
create policy titulaire on public.cotisations for select to authenticated using (client_id = gmb_prive.client_courant());
drop policy if exists lecture_backoffice on public.cotisations;
create policy lecture_backoffice on public.cotisations for select to authenticated using (gmb_prive.bo_lecture('ADM-16') or gmb_prive.bo_lecture('ADM-07'));

-- =============================================================================
-- 26. OUVERTURE ADMINISTRATIVE (exploitant, depuis le SQL Editor)
-- Ouvre le compte d'un dossier sans premier versement : aucun crédit, solde 0 €.
-- Exige un motif, une identité complète et des pièces toutes validées ; tracée au
-- journal d'audit. Inaccessible depuis le site.
-- =============================================================================
create or replace function gmb_prive.ouvrir_compte_administratif(p_dossier uuid, p_motif text)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare d record; f record; v record; e record; j record; v_client uuid; v_courant uuid; v_entreprise uuid; v_personne_enfant uuid; v_enfant uuid; v_compte_jeune uuid; v_demande uuid;
begin
  select * into d from public.dossiers where id = p_dossier;
  if d.etat = 'compte_ouvert' or exists (select 1 from public.clients where dossier_origine_id = p_dossier) then
    raise exception 'Le compte de ce dossier est déjà ouvert.' using errcode = '55000';
  end if;
  select * into f from public.formules where code = coalesce(d.formule_code, 'luna');
  select * into v from public.premiers_versements where dossier_id = p_dossier;
  -- Ouverture administrative : le premier versement est remplacé par des contrôles explicites
  if coalesce(length(trim(p_motif)), 0) < 10 then
    raise exception 'Indiquez le motif de l''ouverture administrative (10 caractères au moins).' using errcode = '22023';
  end if;
  if d.type <> 'ouverture' then
    raise exception 'Ouverture administrative réservée aux dossiers d''ouverture de compte.' using errcode = '55000';
  end if;
  if exists (select 1 from public.personnes p where p.id = d.personne_id and (coalesce(trim(p.nom_naissance), '') = '' or coalesce(trim(p.prenoms), '') = ''
             or p.date_naissance is null or coalesce(trim(p.adresse_ligne1), '') = '' or coalesce(trim(p.code_postal), '') = '' or coalesce(trim(p.ville), '') = '' or coalesce(trim(p.telephone), '') = '')) then
    raise exception 'Identité ou coordonnées incomplètes : remplissez d''abord les étapes 1 et 2 du tunnel.' using errcode = '55000';
  end if;
  if exists (select 1 from public.dossier_pieces x where x.dossier_id = p_dossier and x.statut not in ('validee', 'facultative')) then
    raise exception 'Toutes les pièces doivent être validées avant l''ouverture.' using errcode = '55000';
  end if;
  -- Parcours d'états autorisé (brouillon, déposé, en vérification, validé), visible dans l'historique
  if d.etat = 'brouillon' then update public.dossiers set etat = 'depose', depose_le = coalesce(depose_le, now()) where id = p_dossier; end if;
  if (select etat from public.dossiers where id = p_dossier) in ('depose', 'incomplet') then update public.dossiers set etat = 'en_verification' where id = p_dossier; end if;
  if (select etat from public.dossiers where id = p_dossier) in ('en_verification', 'analyse_conformite') then update public.dossiers set etat = 'valide' where id = p_dossier; end if;
  if (select etat from public.dossiers where id = p_dossier) <> 'valide' then
    raise exception 'Ce dossier ne peut pas être ouvert depuis l''état « % ».', (select etat from public.dossiers where id = p_dossier) using errcode = '55000';
  end if;
  insert into public.clients (personne_id, identifiant, segment, formule_code, dossier_origine_id, ficoba_declare_le)
  values (d.personne_id, gmb_prive.nouvel_identifiant(), case when d.segment = 'jeunes' then 'particulier' else d.segment end, f.code, p_dossier, now())
  returning id into v_client;
  if d.segment in ('pro', 'business') then
    select * into e from public.dossier_entreprises where dossier_id = p_dossier;
    if not found then
      raise exception 'Les informations de l''entreprise manquent : ouverture impossible.' using errcode = '55000';
    end if;
    if exists (select 1 from public.entreprises where siren = e.siren) then
      raise exception 'Une entreprise portant ce SIREN est déjà cliente.' using errcode = '23505';
    end if;
    insert into public.entreprises (raison_sociale, siren, forme, formule_code, adresse)
    values (e.raison_sociale, e.siren, e.forme_juridique, f.code, e.adresse_siege || ', ' || e.code_postal || ' ' || e.ville)
    returning id into v_entreprise;
    insert into public.entreprise_membres (entreprise_id, client_id, role, statut) values (v_entreprise, v_client, 'administrateur', 'actif');
  end if;
  if d.segment = 'business' then
    insert into public.comptes (entreprise_id, type, libelle, numero)
    values (v_entreprise, 'business', 'Compte Business', gmb_prive.nouveau_numero_compte())
    returning id into v_courant;
  else
    insert into public.comptes (client_id, type, libelle, numero)
    values (v_client, case when d.segment = 'pro' then 'pro' else 'courant' end,
            case when d.segment = 'pro' then 'Compte professionnel' else 'Compte courant' end, gmb_prive.nouveau_numero_compte())
    returning id into v_courant;
  end if;
  if f.taux_livret is not null and d.segment in ('particulier', 'jeunes') then
    insert into public.comptes (client_id, type, libelle, taux, plafond, numero)
    values (v_client, 'livret', 'Livret GMB', f.taux_livret, 100000, gmb_prive.nouveau_numero_compte());
  end if;
  if d.segment = 'jeunes' then
    select * into j from public.dossier_jeunes where dossier_id = p_dossier;
    if not found then
      raise exception 'Les informations de l''enfant manquent : ouverture impossible.' using errcode = '55000';
    end if;
    insert into public.personnes (civilite, nom_naissance, prenoms, date_naissance, lieu_naissance, pays_naissance, nationalite,
                                  adresse_ligne1, adresse_ligne2, code_postal, ville, pays, residence_fiscale)
    select j.civilite, j.nom, j.prenoms, j.date_naissance, j.lieu_naissance, j.pays_naissance, j.nationalite,
           p.adresse_ligne1, p.adresse_ligne2, p.code_postal, p.ville, p.pays, p.residence_fiscale
      from public.personnes p where p.id = d.personne_id
    returning id into v_personne_enfant;
    insert into public.clients (personne_id, identifiant, segment, formule_code)
    values (v_personne_enfant, gmb_prive.nouvel_identifiant(), 'jeunes', 'luna') returning id into v_enfant;
    insert into public.comptes (client_id, type, libelle, numero)
    values (v_enfant, 'jeune', 'Compte Jeunes', gmb_prive.nouveau_numero_compte()) returning id into v_compte_jeune;
    insert into public.comptes_jeunes (compte_id, jeune_client_id, parent_client_id) values (v_compte_jeune, v_enfant, v_client);
  end if;
  if v.statut = 'recu' then
    insert into public.operations (compte_id, type, libelle, montant, categorie_code)
    values (v_courant, 'versement_initial', 'Premier versement', coalesce(v.montant_recu, v.montant), 'transferts');
    update public.premiers_versements set statut = 'credite', credite_le = now() where dossier_id = p_dossier;
  end if;
  update public.dossiers set etat = 'compte_ouvert', ouvert_le = now() where id = p_dossier;
  insert into public.journal_audit (acteur_type, action, objet_type, objet_id, motif, apres) values ('systeme', 'OUVERTURE_ADMINISTRATIVE', 'dossier', p_dossier, trim(p_motif), jsonb_build_object('reference', d.reference, 'etat', 'compte_ouvert', 'premier_versement', 'aucun'));
  -- Dossier combiné : la demande de prêt du nouveau client est créée, à l'étude
  if exists (select 1 from public.dossier_credit where dossier_id = p_dossier) then
    insert into public.demandes (client_id, reference, type, etat, montant, duree_mois, objet, taux_debiteur, taeg, mensualite, cout_total, montant_total_du, donnees)
    select v_client, gmb_prive.reference('CRE'), 'pret_personnel', 'analyse', x.montant, x.duree_mois, x.objet, x.taux_debiteur, x.taeg, x.mensualite, x.cout_total, x.montant_total_du,
           jsonb_build_object('dossier', p_dossier, 'revenus_mensuels', x.revenus_mensuels, 'charges_mensuelles', x.charges_mensuelles, 'consentement_ficp', true)
      from public.dossier_credit x where x.dossier_id = p_dossier
    returning id into v_demande;
    insert into public.demande_evenements (demande_id, etat_avant, etat_apres, libelle_client)
    values (v_demande, null, 'analyse', 'Votre compte est ouvert : votre demande de prêt est à l’étude.');
  end if;
  perform gmb_prive.notifier(v_client, d.demandeur_auth, 'Votre compte est ouvert',
    'Votre identifiant bancaire est disponible dans l''Espace Mon Dossier. Activez ensuite votre accès : un code vous sera envoyé par e-mail.' || case when v_demande is not null then ' Votre demande de prêt est à l''étude : l''offre apparaîtra dans votre Espace client.' else '' end,
    '/mon-dossier/', 'email', 'MSG-COMPTE-OUVERT');
  return v_client;
end $$;
revoke execute on function gmb_prive.ouvrir_compte_administratif(uuid, text) from public, anon, authenticated;

-- =============================================================================
-- 27. MESSAGERIE ET RENDEZ-VOUS (lot E2b)
-- =============================================================================

create table if not exists public.rendez_vous_clients (
  id               uuid primary key default gen_random_uuid(),
  client_id        uuid not null references public.clients(id) on delete cascade,
  debut            timestamptz not null,
  duree_min        int not null default 30 check (duree_min between 15 and 90),
  canal            text not null check (canal in ('telephone', 'video')),
  motif            text not null check (length(motif) between 3 and 500),
  statut           text not null default 'demande' check (statut in ('demande', 'confirme', 'annule', 'termine')),
  collaborateur_id uuid references public.collaborateurs(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
comment on table public.rendez_vous_clients is 'GMB : rendez-vous demandés par les clients (téléphone ou vidéo).';

-- Envoi d'un message : crée le fil si besoin, rouvre un fil clos ; 30 messages par heure au plus
create or replace function public.gmb_message_envoyer(p_contenu text, p_fil uuid default null, p_sujet text default null)
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare v_client uuid := gmb_prive.client_courant(); v_fil uuid := p_fil; v_texte text := trim(coalesce(p_contenu, ''));
begin
  if v_client is null then raise exception 'Connexion requise.' using errcode = '42501'; end if;
  if length(v_texte) < 2 then raise exception 'Écrivez votre message.' using errcode = '22023'; end if;
  if length(v_texte) > 4000 then raise exception 'Votre message ne doit pas dépasser 4 000 caractères.' using errcode = '22023'; end if;
  if (select count(*) from public.messages m join public.fils_messagerie f on f.id = m.fil_id where f.client_id = v_client and m.auteur = 'client' and m.created_at > now() - interval '1 hour') >= 30 then
    raise exception 'Vous avez envoyé beaucoup de messages en peu de temps. Réessayez dans un moment.' using errcode = '55000';
  end if;
  if v_fil is null then
    if length(trim(coalesce(p_sujet, ''))) < 3 or length(trim(p_sujet)) > 120 then raise exception 'Indiquez le sujet de votre message (3 à 120 caractères).' using errcode = '22023'; end if;
    insert into public.fils_messagerie (client_id, sujet, statut) values (v_client, trim(p_sujet), 'ouvert') returning id into v_fil;
  elsif not exists (select 1 from public.fils_messagerie where id = v_fil and client_id = v_client) then
    raise exception 'Conversation introuvable.' using errcode = '42501';
  end if;
  insert into public.messages (fil_id, auteur, auteur_id, contenu) values (v_fil, 'client', auth.uid(), v_texte);
  update public.fils_messagerie set statut = 'ouvert', updated_at = now() where id = v_fil;
  return v_fil;
end $$;

-- Lecture : les messages reçus du fil sont marqués lus
create or replace function public.gmb_messages_lus(p_fil uuid)
returns int language plpgsql volatile security definer set search_path = '' as $$
declare n int;
begin
  if not exists (select 1 from public.fils_messagerie where id = p_fil and client_id = gmb_prive.client_courant()) then raise exception 'Conversation introuvable.' using errcode = '42501'; end if;
  update public.messages set lu_le = now() where fil_id = p_fil and auteur <> 'client' and lu_le is null;
  get diagnostics n = row_count;
  return n;
end $$;

-- Clôture d'un fil par le client
create or replace function public.gmb_fil_clore(p_fil uuid)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  update public.fils_messagerie set statut = 'clos', updated_at = now() where id = p_fil and client_id = gmb_prive.client_courant();
  if not found then raise exception 'Conversation introuvable.' using errcode = '42501'; end if;
end $$;

-- Demande de rendez-vous : jours ouvrés, 9 h à 18 h (heure de Paris), 1 heure à 60 jours d'avance, 3 demandes en attente au plus
create or replace function public.gmb_rdv_demander(p_debut timestamptz, p_canal text, p_motif text)
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare v_client uuid := gmb_prive.client_courant(); v_local timestamp := p_debut at time zone 'Europe/Paris'; v_id uuid;
begin
  if v_client is null then raise exception 'Connexion requise.' using errcode = '42501'; end if;
  if p_canal not in ('telephone', 'video') then raise exception 'Choisissez le téléphone ou la vidéo.' using errcode = '22023'; end if;
  if length(trim(coalesce(p_motif, ''))) < 3 then raise exception 'Indiquez l''objet du rendez-vous.' using errcode = '22023'; end if;
  if p_debut < now() + interval '1 hour' then raise exception 'Choisissez un créneau au moins une heure à l''avance.' using errcode = '22023'; end if;
  if p_debut > now() + interval '60 days' then raise exception 'Choisissez un créneau dans les 60 prochains jours.' using errcode = '22023'; end if;
  if extract(isodow from v_local) > 5 or v_local::time < time '09:00' or v_local::time > time '17:30' then
    raise exception 'Choisissez un créneau du lundi au vendredi, de 9 h à 18 h (heure de Paris).' using errcode = '22023';
  end if;
  if (select count(*) from public.rendez_vous_clients where client_id = v_client and statut = 'demande') >= 3 then
    raise exception 'Vous avez déjà 3 demandes de rendez-vous en attente.' using errcode = '55000';
  end if;
  if exists (select 1 from public.rendez_vous_clients where client_id = v_client and statut in ('demande', 'confirme') and debut = p_debut) then
    raise exception 'Vous avez déjà demandé ce créneau.' using errcode = '23505';
  end if;
  insert into public.rendez_vous_clients (client_id, debut, canal, motif) values (v_client, p_debut, p_canal, trim(p_motif)) returning id into v_id;
  return v_id;
end $$;

-- Annulation par le client (rendez-vous à venir)
create or replace function public.gmb_rdv_annuler(p_id uuid)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  update public.rendez_vous_clients set statut = 'annule', updated_at = now()
   where id = p_id and client_id = gmb_prive.client_courant() and statut in ('demande', 'confirme') and debut > now();
  if not found then raise exception 'Ce rendez-vous ne peut plus être annulé.' using errcode = '55000'; end if;
end $$;

-- Back-office : confirmer, annuler ou terminer un rendez-vous (client ou dossier) ; le demandeur est prévenu
create or replace function public.gmb_bo_rdv_statuer(p_source text, p_id uuid, p_statut text)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare r record; v_texte text;
begin
  if not gmb_prive.bo_decision('ADM-09') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
  if p_statut not in ('confirme', 'annule', 'termine') then raise exception 'Statut inconnu.' using errcode = '22023'; end if;
  if p_source = 'client' then
    update public.rendez_vous_clients set statut = p_statut, collaborateur_id = auth.uid(), updated_at = now()
     where id = p_id and statut in ('demande', 'confirme') returning * into r;
  elsif p_source = 'dossier' then
    update public.dossier_rendez_vous set statut = p_statut where id = p_id and statut in ('demande', 'confirme') returning * into r;
  else raise exception 'Origine inconnue.' using errcode = '22023';
  end if;
  if r.id is null then raise exception 'Rendez-vous introuvable ou déjà traité.' using errcode = '55000'; end if;
  v_texte := format('Votre rendez-vous du %s à %s (%s) est %s.', to_char(r.debut at time zone 'Europe/Paris', 'DD/MM/YYYY'), to_char(r.debut at time zone 'Europe/Paris', 'HH24"h"MI'),
                    case when r.canal = 'video' then 'vidéo' else 'téléphone' end, case p_statut when 'confirme' then 'confirmé' when 'annule' then 'annulé' else 'terminé' end);
  if p_source = 'client' then
    perform gmb_prive.notifier(r.client_id, null, 'Rendez-vous ' || case p_statut when 'confirme' then 'confirmé' when 'annule' then 'annulé' else 'terminé' end, v_texte, null, 'in_app', null);
  else
    insert into public.dossier_messages (dossier_id, auteur, contenu) values (r.dossier_id, 'systeme', v_texte);
  end if;
end $$;

drop policy if exists titulaire on public.rendez_vous_clients;
create policy titulaire on public.rendez_vous_clients for select to authenticated using (client_id = gmb_prive.client_courant());
drop policy if exists lecture_backoffice on public.rendez_vous_clients;
create policy lecture_backoffice on public.rendez_vous_clients for select to authenticated using (gmb_prive.bo_lecture('ADM-09'));

-- =============================================================================
-- 28. PARAMÈTRES : CODE SECRET, COORDONNÉES, FERMETURE DU COMPTE (lot E2c)
-- =============================================================================

create table if not exists public.demandes_cloture (
  id                     uuid primary key default gen_random_uuid(),
  client_id              uuid not null references public.clients(id) on delete cascade,
  motif                  text not null check (motif in ('ne_convient_plus', 'frais', 'autre_banque', 'demenagement_etranger', 'autre')),
  precision_motif        text,
  iban_restitution       text not null,
  titulaire_restitution  text not null,
  statut                 text not null default 'demandee' check (statut in ('demandee', 'traitee', 'refusee', 'annulee')),
  motif_refus            text,
  created_at             timestamptz not null default now(),
  traitee_le             timestamptz
);
create unique index if not exists demandes_cloture_une_en_cours on public.demandes_cloture (client_id) where statut = 'demandee';
comment on table public.demandes_cloture is 'GMB : demandes de fermeture de compte (restitution du solde sur un IBAN).';

-- Saisie sur un clavier aléatoire du client connecté, traduite en chiffres ; le clavier est consommé
create or replace function gmb_prive.decoder_clavier(p_grille uuid, p_positions int[])
returns text language plpgsql volatile security definer set search_path = '' as $$
declare g record; v text;
begin
  select * into g from gmb_prive.grilles_clavier where id = p_grille for update;
  if g.id is null or g.utilisee or g.expire_le < now() or g.identifiant is distinct from (select identifiant from public.clients where auth_user_id = auth.uid()) then
    raise exception 'Le clavier a expiré : recommencez la saisie.' using errcode = '55000';
  end if;
  select string_agg(g.disposition[p]::text, '' order by o) into v from unnest(p_positions) with ordinality as u(p, o) where g.disposition[p] between 0 and 9;
  if v is null or length(v) <> coalesce(array_length(p_positions, 1), 0) then raise exception 'Saisie invalide : recommencez.' using errcode = '22023'; end if;
  update gmb_prive.grilles_clavier set utilisee = true where id = p_grille;
  return v;
end $$;
revoke execute on function gmb_prive.decoder_clavier(uuid, int[]) from public, anon, authenticated;

-- Changement du code secret : code actuel (vérification forte), nouveau code saisi deux fois
create or replace function public.gmb_code_secret_changer(p_grille_actuel uuid, p_actuel int[], p_grille_nouveau uuid, p_nouveau int[], p_grille_confirmation uuid, p_confirmation int[])
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_client uuid := gmb_prive.client_courant(); v_actuel text; v_nouveau text; v_confirmation text; r jsonb;
begin
  if v_client is null then raise exception 'Connexion à l''Espace client requise.' using errcode = '42501'; end if;
  select string_agg(g.disposition[p]::text, '' order by o) into v_actuel from gmb_prive.grilles_clavier g, unnest(p_actuel) with ordinality as u(p, o) where g.id = p_grille_actuel;
  v_nouveau := gmb_prive.decoder_clavier(p_grille_nouveau, p_nouveau);
  v_confirmation := gmb_prive.decoder_clavier(p_grille_confirmation, p_confirmation);
  r := gmb_prive.sca_verifier(p_grille_actuel, p_actuel);
  if r ->> 'statut' <> 'ok' then return r; end if;
  if v_nouveau <> v_confirmation then raise exception 'Les deux saisies du nouveau code sont différentes.' using errcode = '22023'; end if;
  if v_nouveau = v_actuel then raise exception 'Choisissez un code différent de votre code actuel.' using errcode = '22023'; end if;
  perform gmb_prive.definir_code(v_client, v_nouveau);
  insert into public.journal_audit (acteur_id, acteur_type, action, objet_type, objet_id, motif) values (auth.uid(), 'client', 'CODE_SECRET_CHANGE', 'client', v_client, 'Changement par le client');
  perform gmb_prive.notifier(v_client, null, 'Code secret modifié', 'Votre code secret a été modifié. Si vous n’êtes pas à l’origine de ce changement, contactez immédiatement le service clients.', null, 'in_app', null);
  return jsonb_build_object('statut', 'ok');
end $$;

-- Coordonnées : téléphone et adresse (en France), confirmés par le code secret
create or replace function public.gmb_client_coordonnees(p_telephone text, p_adresse_ligne1 text, p_adresse_ligne2 text, p_code_postal text, p_ville text, p_grille uuid, p_positions int[])
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_client uuid := gmb_prive.client_courant(); v_personne uuid; v_tel text := regexp_replace(coalesce(p_telephone, ''), '[\s.()-]', '', 'g'); r jsonb; v_avant jsonb; v_apres jsonb;
begin
  if v_client is null then raise exception 'Connexion à l''Espace client requise.' using errcode = '42501'; end if;
  -- Format international (+33…) : un numéro français à 10 chiffres et le préfixe 00 sont convertis
  if v_tel ~ '^0[1-9][0-9]{8}$' then v_tel := '+33' || substr(v_tel, 2);
  elsif v_tel ~ '^00[1-9][0-9]{7,14}$' then v_tel := '+' || substr(v_tel, 3);
  end if;
  if v_tel !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'Indiquez un numéro de téléphone valide, par exemple 06 12 34 56 78 ou +33 6 12 34 56 78.' using errcode = '22023'; end if;
  if length(trim(coalesce(p_adresse_ligne1, ''))) < 3 then raise exception 'Indiquez votre adresse.' using errcode = '22023'; end if;
  if coalesce(p_code_postal, '') !~ '^[0-9]{5}$' then raise exception 'Indiquez un code postal français à 5 chiffres. Pour une adresse à l''étranger, écrivez au service clients.' using errcode = '22023'; end if;
  if length(trim(coalesce(p_ville, ''))) < 2 then raise exception 'Indiquez votre ville.' using errcode = '22023'; end if;
  r := gmb_prive.sca_verifier(p_grille, p_positions);
  if r ->> 'statut' <> 'ok' then return r; end if;
  select personne_id into v_personne from public.clients where id = v_client;
  select jsonb_build_object('telephone', telephone, 'adresse_ligne1', adresse_ligne1, 'adresse_ligne2', adresse_ligne2, 'code_postal', code_postal, 'ville', ville) into v_avant from public.personnes where id = v_personne;
  update public.personnes set telephone = v_tel, adresse_ligne1 = trim(p_adresse_ligne1), adresse_ligne2 = nullif(trim(coalesce(p_adresse_ligne2, '')), ''), code_postal = p_code_postal, ville = trim(p_ville) where id = v_personne
  returning jsonb_build_object('telephone', telephone, 'adresse_ligne1', adresse_ligne1, 'adresse_ligne2', adresse_ligne2, 'code_postal', code_postal, 'ville', ville) into v_apres;
  insert into public.journal_audit (acteur_id, acteur_type, action, objet_type, objet_id, avant, apres, motif) values (auth.uid(), 'client', 'COORDONNEES_MODIFIEES', 'personne', v_personne, v_avant, v_apres, 'Modification par le client');
  perform gmb_prive.notifier(v_client, null, 'Coordonnées modifiées', 'Votre téléphone et votre adresse ont été mis à jour. Si vous n’êtes pas à l’origine de ce changement, contactez immédiatement le service clients.', null, 'in_app', null);
  return jsonb_build_object('statut', 'ok');
end $$;

-- Demande de fermeture du compte, confirmée par le code secret
create or replace function public.gmb_cloture_demander(p_motif text, p_precision text, p_iban text, p_titulaire text, p_grille uuid, p_positions int[])
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_client uuid := gmb_prive.client_courant(); v_iban text := upper(regexp_replace(coalesce(p_iban, ''), '\s', '', 'g')); r jsonb; v_id uuid;
begin
  if v_client is null then raise exception 'Connexion à l''Espace client requise.' using errcode = '42501'; end if;
  if p_motif not in ('ne_convient_plus', 'frais', 'autre_banque', 'demenagement_etranger', 'autre') then raise exception 'Choisissez un motif.' using errcode = '22023'; end if;
  if not gmb_prive.iban_valide(v_iban) then raise exception 'Cet IBAN n''est pas valide : vérifiez-le.' using errcode = '22023'; end if;
  if length(trim(coalesce(p_titulaire, ''))) < 3 then raise exception 'Indiquez le titulaire du compte de restitution.' using errcode = '22023'; end if;
  if exists (select 1 from public.credits where client_id = v_client and statut in ('en_cours', 'impaye')) then
    raise exception 'Un prêt est en cours : remboursez-le, par anticipation si vous le souhaitez, avant de fermer votre compte.' using errcode = '55000';
  end if;
  if exists (select 1 from public.demandes_cloture where client_id = v_client and statut = 'demandee') then raise exception 'Une demande de fermeture est déjà en cours.' using errcode = '23505'; end if;
  r := gmb_prive.sca_verifier(p_grille, p_positions);
  if r ->> 'statut' <> 'ok' then return r; end if;
  insert into public.demandes_cloture (client_id, motif, precision_motif, iban_restitution, titulaire_restitution) values (v_client, p_motif, nullif(trim(coalesce(p_precision, '')), ''), v_iban, trim(p_titulaire)) returning id into v_id;
  insert into public.journal_audit (acteur_id, acteur_type, action, objet_type, objet_id, motif) values (auth.uid(), 'client', 'CLOTURE_DEMANDEE', 'client', v_client, p_motif);
  perform gmb_prive.notifier(v_client, null, 'Demande de fermeture reçue', 'Votre demande de fermeture est enregistrée. Le solde sera restitué sur l’IBAN indiqué et votre compte fermé sous 30 jours au plus, sans frais.', null, 'in_app', null);
  return jsonb_build_object('statut', 'ok', 'demande', v_id);
end $$;

create or replace function public.gmb_cloture_annuler(p_id uuid)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  update public.demandes_cloture set statut = 'annulee' where id = p_id and client_id = gmb_prive.client_courant() and statut = 'demandee';
  if not found then raise exception 'Cette demande ne peut plus être annulée.' using errcode = '55000'; end if;
end $$;

-- Back-office : clôture effectuée (solde restitué au préalable) ou refus motivé
create or replace function public.gmb_bo_cloture_traiter(p_id uuid, p_decision text, p_motif text default null)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare dmd record; v_solde numeric;
begin
  if not gmb_prive.bo_decision('ADM-07') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
  select * into dmd from public.demandes_cloture where id = p_id and statut = 'demandee' for update;
  if dmd.id is null then raise exception 'Demande introuvable ou déjà traitée.' using errcode = '55000'; end if;
  if p_decision = 'traitee' then
    select coalesce(sum(solde), 0) into v_solde from public.comptes where client_id = dmd.client_id and statut <> 'cloture';
    if v_solde <> 0 then raise exception 'Restituez d''abord le solde (% €) sur l''IBAN indiqué, puis clôturez.', gmb_prive.euros(v_solde) using errcode = '55000'; end if;
    update public.comptes set statut = 'cloture' where client_id = dmd.client_id and statut <> 'cloture';
    update public.clients set statut = 'cloture', cloture_le = now() where id = dmd.client_id;
    update public.demandes_cloture set statut = 'traitee', traitee_le = now() where id = p_id;
    perform gmb_prive.notifier(dmd.client_id, null, 'Compte fermé', 'Votre compte GerMoonBank est fermé. Merci de nous avoir fait confiance.', null, 'in_app', null);
  elsif p_decision = 'refusee' then
    if length(trim(coalesce(p_motif, ''))) < 10 then raise exception 'Indiquez le motif du refus (10 caractères au moins).' using errcode = '22023'; end if;
    update public.demandes_cloture set statut = 'refusee', motif_refus = trim(p_motif), traitee_le = now() where id = p_id;
    perform gmb_prive.notifier(dmd.client_id, null, 'Demande de fermeture', 'Votre demande de fermeture n’a pas pu aboutir : ' || trim(p_motif), null, 'in_app', null);
  else raise exception 'Décision inconnue.' using errcode = '22023';
  end if;
  insert into public.journal_audit (acteur_id, acteur_type, action, objet_type, objet_id, motif) values (auth.uid(), 'backoffice', 'CLOTURE_' || upper(p_decision), 'client', dmd.client_id, p_motif);
end $$;

drop policy if exists titulaire on public.demandes_cloture;
create policy titulaire on public.demandes_cloture for select to authenticated using (client_id = gmb_prive.client_courant());
drop policy if exists lecture_backoffice on public.demandes_cloture;
create policy lecture_backoffice on public.demandes_cloture for select to authenticated using (gmb_prive.bo_lecture('ADM-07'));


-- Connexion à l'Espace client : décodage du clavier et appareils de confiance (AUTH-03, AUTH-05)
create or replace function public.gmb_clavier_decoder(p_grille uuid, p_positions int[])
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  g record;
  p int;
  v_code text := '';
begin
  select * into g from gmb_prive.grilles_clavier where id = p_grille for update;
  if not found or g.utilisee or g.expire_le < now() then
    raise exception 'Le clavier a expiré. Un nouveau clavier vous est proposé.' using errcode = '55000';
  end if;
  update gmb_prive.grilles_clavier set utilisee = true where id = p_grille;
  if coalesce(array_length(p_positions, 1), 0) <> 8 then
    raise exception 'Le code secret comporte 8 chiffres.' using errcode = '22023';
  end if;
  foreach p in array p_positions loop
    if p < 1 or p > 12 or g.disposition[p] < 0 then
      raise exception 'Saisie invalide.' using errcode = '22023';
    end if;
    v_code := v_code || g.disposition[p]::text;
  end loop;
  return v_code;
end
$$;

create or replace function public.gmb_appareil_enregistrer(p_client uuid, p_nom text, p_plateforme text, p_cle_hash text)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if p_client is null or coalesce(p_cle_hash, '') !~ '^[0-9a-f]{64}$' then
    raise exception 'Appareil invalide.' using errcode = '22023';
  end if;
  insert into public.appareils (client_id, nom, plateforme, cle_publique, ajoute_le, derniere_utilisation)
  values (p_client, left(coalesce(nullif(p_nom, ''), 'Navigateur'), 80), left(coalesce(p_plateforme, 'web'), 20), p_cle_hash, now(), now())
  returning id into v_id;
  perform gmb_prive.notifier(p_client, null, 'Nouvel appareil de confiance',
    'Un nouvel appareil a été ajouté à votre Espace client. Si ce n''était pas vous, révoquez-le et contactez-nous.', '/profil/securite', 'email', 'MSG-NOUVEL-APPAREIL');
  return v_id;
end
$$;

create or replace function public.gmb_appareil_reconnaitre(p_client uuid, p_appareil uuid, p_cle_hash text)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  update public.appareils
     set derniere_utilisation = now()
   where id = p_appareil and client_id = p_client and cle_publique = p_cle_hash and revoque_le is null;
  return found;
end
$$;


-- =============================================================================
-- 29. EXPLOITATION : VERSION DE LA BASE, COMPTE DE RÉCEPTION, ÉTAT DE L'INSTALLATION
-- =============================================================================

-- Version de la base. Le site la compare à celle qu'il attend : le back-office
-- signale aussitôt une base qui n'a pas reçu la dernière mise à niveau.
create or replace function public.gmb_version() returns int
language sql immutable set search_path = '' as $$ select 20261009 $$;

-- Compte bancaire qui reçoit les virements (premiers versements, fonds destinés aux
-- clients) : saisi au back-office par la trésorerie (ADM-16), contrôlé, et tracé au
-- journal d'audit avec les valeurs d'avant et d'après. Tout changement exige un motif.
create or replace function public.gmb_bo_collecte_configurer(p_titulaire text, p_iban text, p_bic text default null,
                                                             p_banque text default null, p_motif text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_avant jsonb; v_apres jsonb;
        v_iban text := upper(regexp_replace(coalesce(p_iban, ''), '\s', '', 'g'));
        v_bic text := upper(regexp_replace(coalesce(p_bic, ''), '\s', '', 'g'));
begin
  if not gmb_prive.bo_ecriture('ADM-16') then
    raise exception 'Droits insuffisants : le compte de réception est réglé par la trésorerie.' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_titulaire, ''))) < 2 then
    raise exception 'Indiquez le titulaire du compte, tel qu''il figure sur le relevé d''identité bancaire.' using errcode = '22023';
  end if;
  if not gmb_prive.iban_valide(v_iban) then
    raise exception 'Cet IBAN n''est pas valide : vérifiez-le sur le relevé d''identité bancaire.' using errcode = '22023';
  end if;
  if v_bic <> '' and v_bic !~ '^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$' then
    raise exception 'Ce BIC n''est pas valide : il comporte 8 ou 11 caractères. Laissez la case vide si vous ne le connaissez pas.' using errcode = '22023';
  end if;
  select coalesce(jsonb_object_agg(cle, valeur), '{}'::jsonb) into v_avant from public.parametres_banque where cle like 'collecte%';
  if coalesce(v_avant ->> 'collecte_iban', '') <> '' and length(btrim(coalesce(p_motif, ''))) < 5 then
    raise exception 'Indiquez le motif de ce changement de compte de réception.' using errcode = '22023';
  end if;
  perform gmb_prive.configurer_collecte(btrim(p_titulaire), v_iban, v_bic, btrim(coalesce(p_banque, '')));
  select jsonb_object_agg(cle, valeur) into v_apres from public.parametres_banque where cle like 'collecte%';
  insert into public.journal_audit (acteur_id, acteur_type, action, objet_type, objet_id, avant, apres, motif)
  values (auth.uid(), 'backoffice', 'COMPTE_RECEPTION', 'parametres_banque', 'collecte', v_avant, v_apres,
          coalesce(nullif(btrim(coalesce(p_motif, '')), ''), 'Première configuration'));
  return v_apres;
end $$;

-- GerMoonBank · installation de la base, partie 7 sur 8
-- Exécutez les parties dans l'ordre, chacune dans une requête vide du SQL Editor.
-- Contenu : 03_fonctions, 04_declencheurs_securite
-- État de l'installation, affiché au tableau de bord du back-office : version de la
-- base, compte de réception, tâches quotidiennes, dossiers en attente.
create or replace function public.gmb_bo_etat_installation()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_taches jsonb := '[]'::jsonb; v_collecte jsonb;
begin
  if not gmb_prive.est_collaborateur() then
    raise exception 'Droits insuffisants.' using errcode = '42501';
  end if;
  if to_regclass('cron.job') is not null then
    execute $q$select coalesce(jsonb_agg(jobname order by jobname), '[]'::jsonb) from cron.job where active and jobname like 'gmb-%'$q$ into v_taches;
  end if;
  select coalesce(jsonb_object_agg(cle, valeur), '{}'::jsonb) into v_collecte from public.parametres_banque where cle like 'collecte%';
  return jsonb_build_object(
    'version', public.gmb_version(),
    'collecte', v_collecte,
    'taches', v_taches,
    'regles_acces_actives', (select count(*) from pg_catalog.pg_tables where schemaname = 'public' and rowsecurity),
    'tables', (select count(*) from pg_catalog.pg_tables where schemaname = 'public'),
    'dossiers', (select jsonb_build_object(
        'non_deposes', count(*) filter (where etat = 'brouillon'),
        'a_traiter', count(*) filter (where etat in ('depose', 'en_verification', 'analyse_conformite', 'demande_deposee', 'analyse')),
        'attente_demandeur', count(*) filter (where etat = 'incomplet')) from public.dossiers),
    'versements_attendus', (select count(*) from public.premiers_versements where statut = 'attendu'));
end $$;


-- =============================================================================
-- 30. CARTES : COMMANDE ET ACTIVATION ; IBAN ATTRIBUÉ À UN COMPTE (lot E3b)
-- =============================================================================
-- Le client commande une carte physique ou demande une carte virtuelle depuis son
-- Espace client, en confirmant par son code secret, dans la limite de cartes de sa
-- formule. Le back-office transmet la commande à l'émetteur des cartes, puis
-- enregistre la carte émise : quatre derniers chiffres et date d'expiration, jamais
-- le numéro complet ni le cryptogramme. Une carte physique arrive « commandée » et le
-- client l'active à réception ; une carte virtuelle est active dès son émission.
-- L'IBAN d'un compte est celui que lui attribue l'établissement teneur du compte : le
-- back-office l'enregistre (clé de contrôle vérifiée, tracé au journal d'audit) et le
-- client le retrouve dans son relevé d'identité bancaire.

create table if not exists public.commandes_cartes (
  id           uuid primary key default gen_random_uuid(),
  client_id    uuid not null references public.clients(id) on delete cascade,
  compte_id    uuid not null references public.comptes(id) on delete cascade,
  type         text not null check (type in ('physique', 'virtuelle')),
  gamme        text not null,
  livraison    jsonb,
  statut       text not null default 'demandee' check (statut in ('demandee', 'transmise', 'emise', 'refusee', 'annulee')),
  motif_refus  text,
  carte_id     uuid references public.cartes(id) on delete set null,
  traitee_par  uuid,
  traitee_le   timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
comment on table public.commandes_cartes is 'GMB : commandes de cartes physiques et virtuelles, de la demande du client à l''émission (lot E3b).';
create index if not exists commandes_cartes_client_idx on public.commandes_cartes (client_id, created_at desc);
create unique index if not exists commandes_cartes_en_cours_idx on public.commandes_cartes (compte_id, type) where statut in ('demandee', 'transmise');

-- Commande par le client : code secret obligatoire ; une commande en cours au plus
-- par compte et par type ; nombre de cartes limité par la formule.
create or replace function public.gmb_carte_commander(p_compte uuid, p_type text, p_livraison jsonb, p_grille uuid, p_positions int[])
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_client uuid := gmb_prive.client_courant(); k record; f record; v_gamme text; v_max int; v_nb int; v_livraison jsonb; r jsonb; v_id uuid;
begin
  if v_client is null then raise exception 'Connexion à l''Espace client requise.' using errcode = '42501'; end if;
  if p_type is null or p_type not in ('physique', 'virtuelle') then raise exception 'Choisissez une carte physique ou une carte virtuelle.' using errcode = '22023'; end if;
  select * into k from public.comptes where id = p_compte;
  if not found or not gmb_prive.compte_accessible(p_compte) then raise exception 'Compte introuvable.' using errcode = '42501'; end if;
  if k.statut <> 'actif' or k.type not in ('courant', 'jeune', 'pro', 'business') then
    raise exception 'Une carte se rattache à un compte de paiement actif.' using errcode = '22023';
  end if;
  select fo.nom, fo.cartes_physiques, fo.cartes_virtuelles into f
    from public.clients c left join public.formules fo on fo.code = c.formule_code where c.id = v_client;
  v_gamme := coalesce(f.nom, 'GerMoonBank');
  v_max := case p_type when 'physique' then coalesce(f.cartes_physiques, 1) else coalesce(f.cartes_virtuelles, 1) end;
  select count(*) into v_nb from public.cartes where titulaire_client_id = v_client and type = p_type and statut in ('commandee', 'active', 'gelee');
  v_nb := v_nb + (select count(*) from public.commandes_cartes where client_id = v_client and type = p_type and statut in ('demandee', 'transmise'));
  if v_nb >= v_max then
    raise exception '%', case when v_max = 1
      then format('Votre formule %s comprend une carte %s : elle est déjà émise ou commandée.', v_gamme, p_type)
      else format('Votre formule %s comprend %s cartes %ss : elles sont toutes déjà émises ou commandées.', v_gamme, v_max, p_type) end
      using errcode = '55000';
  end if;
  if exists (select 1 from public.commandes_cartes where compte_id = p_compte and type = p_type and statut in ('demandee', 'transmise')) then
    raise exception 'Une commande de carte % est déjà en cours pour ce compte.', p_type using errcode = '23505';
  end if;
  if p_type = 'physique' then
    v_livraison := jsonb_build_object(
      'nom', btrim(coalesce(p_livraison ->> 'nom', '')),
      'ligne1', btrim(coalesce(p_livraison ->> 'ligne1', '')),
      'ligne2', nullif(btrim(coalesce(p_livraison ->> 'ligne2', '')), ''),
      'code_postal', btrim(coalesce(p_livraison ->> 'code_postal', '')),
      'ville', btrim(coalesce(p_livraison ->> 'ville', '')),
      'pays', upper(btrim(coalesce(p_livraison ->> 'pays', 'FR'))));
    if length(v_livraison ->> 'ligne1') < 3 or length(v_livraison ->> 'code_postal') < 2 or length(v_livraison ->> 'ville') < 2 then
      raise exception 'Indiquez l''adresse de livraison complète : rue, code postal et ville.' using errcode = '22023';
    end if;
    if (v_livraison ->> 'pays') !~ '^[A-Z]{2}$' then raise exception 'Le pays de livraison n''est pas valide.' using errcode = '22023'; end if;
  end if;
  r := gmb_prive.sca_verifier(p_grille, p_positions);
  if r ->> 'statut' <> 'ok' then return r; end if;
  insert into public.commandes_cartes (client_id, compte_id, type, gamme, livraison)
  values (v_client, p_compte, p_type, v_gamme, v_livraison) returning id into v_id;
  insert into public.journal_audit (acteur_id, acteur_type, action, objet_type, objet_id, apres)
  values (auth.uid(), 'client', 'CARTE_COMMANDEE', 'commandes_cartes', v_id::text, jsonb_build_object('type', p_type, 'compte', p_compte, 'gamme', v_gamme));
  perform gmb_prive.notifier(v_client, null,
    case p_type when 'physique' then 'Commande de carte enregistrée' else 'Demande de carte virtuelle enregistrée' end,
    case p_type when 'physique' then format('Votre commande de carte %s est enregistrée. Vous serez prévenu de son envoi.', v_gamme)
                else format('Votre demande de carte virtuelle %s est enregistrée. Vous serez prévenu dès qu’elle sera disponible.', v_gamme) end,
    null, 'in_app', null);
  return jsonb_build_object('statut', 'ok', 'commande', v_id);
end $$;

-- Annulation par le client, tant que la commande n'est pas transmise à l'émetteur
create or replace function public.gmb_carte_commande_annuler(p_commande uuid)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  update public.commandes_cartes set statut = 'annulee', traitee_le = now()
   where id = p_commande and client_id = gmb_prive.client_courant() and statut = 'demandee';
  if not found then raise exception 'Cette commande ne peut plus être annulée.' using errcode = '55000'; end if;
end $$;

-- Activation d'une carte physique à réception : les 4 derniers chiffres imprimés sur la carte
create or replace function public.gmb_carte_activer(p_carte uuid, p_chiffres text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare k record;
begin
  if not gmb_prive.carte_accessible(p_carte) then raise exception 'Carte introuvable.' using errcode = '42501'; end if;
  select * into k from public.cartes where id = p_carte for update;
  if k.statut <> 'commandee' then raise exception 'Cette carte est déjà activée.' using errcode = '55000'; end if;
  if btrim(coalesce(p_chiffres, '')) <> k.derniers_chiffres then
    raise exception 'Ces chiffres ne correspondent pas : saisissez les 4 derniers chiffres imprimés sur votre carte.' using errcode = '22023';
  end if;
  update public.cartes set statut = 'active' where id = p_carte;
  perform gmb_prive.notifier(k.titulaire_client_id, null, 'Carte activée', format('Votre carte •••• %s est active.', k.derniers_chiffres), null, 'in_app', null);
  return jsonb_build_object('statut', 'active');
end $$;

-- Back-office (ADM-07) : transmission à l'émetteur, carte émise, ou refus motivé
create or replace function public.gmb_bo_carte_commande_traiter(p_commande uuid, p_decision text, p_chiffres text default null,
                                                                p_expiration text default null, p_motif text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare c record; v_carte uuid;
begin
  if not gmb_prive.bo_ecriture('ADM-07') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
  select * into c from public.commandes_cartes where id = p_commande for update;
  if not found then raise exception 'Commande introuvable.' using errcode = 'P0002'; end if;
  if c.statut not in ('demandee', 'transmise') then raise exception 'Cette commande est déjà traitée.' using errcode = '55000'; end if;
  if p_decision = 'transmise' then
    if c.statut = 'transmise' then raise exception 'Cette commande est déjà transmise à l''émetteur.' using errcode = '55000'; end if;
    update public.commandes_cartes set statut = 'transmise', traitee_par = auth.uid(), traitee_le = now() where id = p_commande;
  elsif p_decision = 'emise' then
    if coalesce(p_chiffres, '') !~ '^[0-9]{4}$' then raise exception 'Indiquez les 4 derniers chiffres de la carte émise.' using errcode = '22023'; end if;
    if coalesce(p_expiration, '') !~ '^(0[1-9]|1[0-2])/[0-9]{2}$' then raise exception 'Indiquez la date d''expiration au format MM/AA.' using errcode = '22023'; end if;
    if (make_date(2000 + substr(p_expiration, 4, 2)::int, substr(p_expiration, 1, 2)::int, 1) + interval '1 month')::date <= current_date then
      raise exception 'Cette date d''expiration est dépassée.' using errcode = '22023';
    end if;
    insert into public.cartes (compte_id, titulaire_client_id, type, gamme, derniers_chiffres, expiration, statut)
    values (c.compte_id, c.client_id, c.type, c.gamme, p_chiffres, p_expiration, case c.type when 'physique' then 'commandee' else 'active' end)
    returning id into v_carte;
    update public.commandes_cartes set statut = 'emise', carte_id = v_carte, traitee_par = auth.uid(), traitee_le = now() where id = p_commande;
    perform gmb_prive.notifier(c.client_id, null,
      case c.type when 'physique' then 'Votre carte est en route' else 'Votre carte virtuelle est prête' end,
      case c.type when 'physique' then format('Votre carte %s •••• %s vous a été envoyée. Activez-la dès réception, depuis la rubrique Cartes.', c.gamme, p_chiffres)
                  else format('Votre carte virtuelle %s •••• %s est active.', c.gamme, p_chiffres) end,
      null, 'in_app', null);
  elsif p_decision = 'refusee' then
    if length(btrim(coalesce(p_motif, ''))) < 5 then raise exception 'Indiquez le motif communiqué au client.' using errcode = '22023'; end if;
    update public.commandes_cartes set statut = 'refusee', motif_refus = btrim(p_motif), traitee_par = auth.uid(), traitee_le = now() where id = p_commande;
    perform gmb_prive.notifier(c.client_id, null, 'Commande de carte refusée', btrim(p_motif), null, 'in_app', null);
  else
    raise exception 'Décision inconnue.' using errcode = '22023';
  end if;
  insert into public.journal_audit (acteur_id, acteur_type, action, objet_type, objet_id, avant, apres, motif)
  values (auth.uid(), 'backoffice', 'CARTE_COMMANDE_' || upper(p_decision), 'commandes_cartes', p_commande::text,
          jsonb_build_object('statut', c.statut), jsonb_build_object('statut', p_decision, 'carte', v_carte), nullif(btrim(coalesce(p_motif, '')), ''));
  return jsonb_build_object('statut', p_decision, 'carte', v_carte);
end $$;

-- Back-office (ADM-07) : IBAN et BIC attribués au compte par l'établissement teneur du compte
create or replace function public.gmb_bo_compte_iban(p_compte uuid, p_iban text, p_bic text, p_motif text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare k record;
        v_iban text := upper(regexp_replace(coalesce(p_iban, ''), '\s', '', 'g'));
        v_bic text := upper(regexp_replace(coalesce(p_bic, ''), '\s', '', 'g'));
begin
  if not gmb_prive.bo_ecriture('ADM-07') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
  select * into k from public.comptes where id = p_compte for update;
  if not found or k.statut = 'cloture' then raise exception 'Compte introuvable ou clôturé.' using errcode = 'P0002'; end if;
  if not gmb_prive.iban_valide(v_iban) then
    raise exception 'Cet IBAN n''est pas valide : vérifiez-le sur le document de l''établissement teneur du compte.' using errcode = '22023';
  end if;
  if v_bic !~ '^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$' then raise exception 'Ce BIC n''est pas valide : il comporte 8 ou 11 caractères.' using errcode = '22023'; end if;
  if exists (select 1 from public.comptes where iban = v_iban and id <> p_compte) then
    raise exception 'Cet IBAN est déjà attribué à un autre compte.' using errcode = '23505';
  end if;
  if k.iban is not null and length(btrim(coalesce(p_motif, ''))) < 5 then
    raise exception 'Indiquez le motif du changement d''IBAN.' using errcode = '22023';
  end if;
  update public.comptes set iban = v_iban, bic = v_bic where id = p_compte;
  insert into public.journal_audit (acteur_id, acteur_type, action, objet_type, objet_id, avant, apres, motif)
  values (auth.uid(), 'backoffice', 'COMPTE_IBAN', 'comptes', p_compte::text, jsonb_build_object('iban', k.iban, 'bic', k.bic),
          jsonb_build_object('iban', v_iban, 'bic', v_bic), coalesce(nullif(btrim(coalesce(p_motif, '')), ''), 'Attribution de l''IBAN'));
  if k.client_id is not null then
    perform gmb_prive.notifier(k.client_id, null, 'Votre IBAN est disponible',
      'Votre relevé d’identité bancaire (RIB) est disponible dans la rubrique Comptes : communiquez-le pour recevoir vos virements et prélèvements.', null, 'in_app', null);
  end if;
  return jsonb_build_object('iban', v_iban, 'bic', v_bic);
end $$;

-- Fonds reçus d'une autre banque sur le compte de réception (ADM-16) : le virement est
-- crédité au client avec tout ce qui l'identifie — émetteur, IBAN de l'émetteur, motif
-- (communication du virement) et référence bancaire — visibles dans la fiche de l'opération.
drop function if exists public.gmb_bo_fonds_recus(text, numeric, text, text);
create or replace function public.gmb_bo_fonds_recus(p_numero_compte text, p_montant numeric, p_emetteur text, p_reference text default null,
                                                     p_iban_emetteur text default null, p_motif text default null)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare k record; v_iban text := nullif(upper(regexp_replace(coalesce(p_iban_emetteur, ''), '\s', '', 'g')), '');
begin
  if not gmb_prive.bo_decision('ADM-16') then
    raise exception 'Droits insuffisants.' using errcode = '42501';
  end if;
  select * into k from public.comptes where numero = replace(coalesce(p_numero_compte, ''), ' ', '') and statut = 'actif';
  if not found then
    raise exception 'Aucun compte GerMoonBank actif ne porte ce numéro.' using errcode = '22023';
  end if;
  if p_montant is null or p_montant <= 0 then
    raise exception 'Indiquez le montant reçu.' using errcode = '22023';
  end if;
  if v_iban is not null and not gmb_prive.iban_valide(v_iban) then
    raise exception 'L''IBAN de l''émetteur n''est pas valide : recopiez-le depuis le relevé du compte de réception.' using errcode = '22023';
  end if;
  insert into public.operations (compte_id, type, libelle, contrepartie_nom, contrepartie_iban, montant, categorie_code, motif, reference)
  values (k.id, 'virement_recu', case when nullif(trim(p_emetteur), '') is null then 'Virement d''une autre banque'
                                      when lower(left(trim(p_emetteur), 1)) in ('a', 'e', 'i', 'o', 'u', 'y', 'h', 'é', 'è', 'ê', 'à', 'â', 'î', 'ô', 'û')
                                      then 'Virement d''' || trim(p_emetteur) else 'Virement de ' || trim(p_emetteur) end,
          nullif(trim(p_emetteur), ''), v_iban,
          p_montant, 'transferts', left(nullif(trim(coalesce(p_motif, '')), ''), 140), nullif(trim(coalesce(p_reference, '')), ''));
  if k.client_id is not null then
    perform gmb_prive.notifier(k.client_id, null, 'Virement reçu',
      format('%s reçus de %s.', gmb_prive.euros(p_montant), coalesce(nullif(trim(p_emetteur), ''), 'une autre banque')), null, 'push');
  end if;
  return jsonb_build_object('statut', 'credite', 'compte', k.numero);
end $$;

drop policy if exists titulaire on public.commandes_cartes;
create policy titulaire on public.commandes_cartes for select to authenticated using (client_id = gmb_prive.client_courant());
drop policy if exists lecture_backoffice on public.commandes_cartes;
create policy lecture_backoffice on public.commandes_cartes for select to authenticated using (gmb_prive.bo_lecture('ADM-07'));

-- =============================================================================
-- 12. DÉCLENCHEURS
-- =============================================================================

-- 12.1 Horodatage updated_at sur toutes les tables GMB qui en ont un
do $$
declare r record;
begin
  for r in select c.relname from pg_class c
             join pg_namespace n on n.oid = c.relnamespace
             join pg_attribute a on a.attrelid = c.oid and a.attname = 'updated_at' and not a.attisdropped
            where n.nspname = 'public' and c.relkind = 'r' and obj_description(c.oid, 'pg_class') like 'GMB%' loop
    execute format('create trigger gmb_maj_horodatage before update on public.%I for each row execute function gmb_prive.maj_horodatage()', r.relname);
  end loop;
end $$;

-- 12.2 Cycle de vie des dossiers (cahier des charges, § 11.2)
create or replace function gmb_prive.dossiers_transition() returns trigger
language plpgsql security definer set search_path = '' as $$
declare ok boolean;
begin
  if new.etat = old.etat then
    return new;
  end if;
  ok := case old.etat
    when 'brouillon'          then new.etat in ('depose', 'demande_deposee', 'abandonne')
    when 'depose'             then new.etat in ('en_verification')
    when 'en_verification'    then new.etat in ('incomplet', 'analyse_conformite', 'valide', 'refuse')
    when 'incomplet'          then new.etat in ('en_verification', 'analyse', 'abandonne', 'refuse', 'refusee')
    when 'analyse_conformite' then new.etat in ('valide', 'refuse', 'incomplet')
    when 'valide'             then new.etat in ('compte_ouvert')
    when 'compte_ouvert'      then new.etat in ('archive')
    when 'refuse'             then new.etat in ('archive')
    when 'abandonne'          then new.etat in ('archive')
    when 'demande_deposee'    then new.etat in ('analyse')
    when 'analyse'            then new.etat in ('offre_emise', 'refusee', 'incomplet')
    when 'offre_emise'        then new.etat in ('delai_legal', 'renonciation')
    when 'delai_legal'        then new.etat in ('acceptee', 'renonciation')
    when 'acceptee'           then new.etat in ('fonds_debloques', 'renonciation')
    when 'fonds_debloques'    then new.etat in ('archive')
    when 'refusee'            then new.etat in ('archive')
    when 'renonciation'       then new.etat in ('archive')
    else false end;
  if not ok then
    raise exception 'Transition interdite : % → %.', old.etat, new.etat using errcode = '55000';
  end if;
  new.derniere_activite := now();
  return new;
end $$;

create or replace function gmb_prive.libelle_etat(p_etat text) returns text
language sql immutable set search_path = '' as $$
  select case p_etat
    when 'brouillon'          then 'Demande en cours de saisie'
    when 'depose'             then 'Dossier déposé'
    when 'en_verification'    then 'Vérification des pièces'
    when 'incomplet'          then 'Une pièce est à remplacer'
    when 'analyse_conformite' then 'Vérifications complémentaires en cours'
    when 'valide'             then 'Votre dossier est accepté'
    when 'compte_ouvert'      then 'Votre identifiant bancaire est disponible'
    when 'refuse'             then 'Nous ne pouvons pas donner une suite favorable à votre demande'
    when 'abandonne'          then 'Demande clôturée'
    when 'archive'            then 'Dossier archivé'
    when 'demande_deposee'    then 'Demande de prêt déposée'
    when 'analyse'            then 'Étude de votre demande'
    when 'offre_emise'        then 'Votre offre de prêt est disponible'
    when 'delai_legal'        then 'Offre signée : délai de rétractation de 14 jours'
    when 'acceptee'           then 'Prêt accepté'
    when 'fonds_debloques'    then 'Fonds versés'
    when 'refusee'            then 'Nous ne pouvons pas donner une suite favorable à votre demande'
    when 'renonciation'       then 'Demande annulée'
    when 'validee'            then 'Demande acceptée'
    when 'realisee'           then 'Demande réalisée'
    when 'annulee'            then 'Demande annulée'
    else p_etat end
$$;

create or replace function gmb_prive.dossiers_evenement() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_libelle text := gmb_prive.libelle_etat(new.etat); v_acteur text;
begin
  v_acteur := case when gmb_prive.est_collaborateur() then 'analyste'
                   when auth.uid() is not null and auth.uid() = new.demandeur_auth then 'client'
                   else 'systeme' end;
  insert into public.dossier_evenements (dossier_id, etat_avant, etat_apres, acteur, libelle_client)
  values (new.id, old.etat, new.etat, v_acteur, v_libelle);
  if new.demandeur_auth is not null and new.etat in ('incomplet', 'valide', 'compte_ouvert', 'refuse', 'offre_emise', 'refusee') then
    insert into public.notifications (destinataire_auth, canal, titre, contenu, lien)
    values (new.demandeur_auth, 'email', v_libelle, format('Votre dossier %s a évolué : %s.', new.reference, lower(v_libelle)),
            '/mon-dossier/?dossier=' || new.reference);
  end if;
  return null;
end $$;

create trigger gmb_dossiers_transition before update of etat on public.dossiers
  for each row execute function gmb_prive.dossiers_transition();
create trigger gmb_dossiers_evenement after update of etat on public.dossiers
  for each row when (old.etat is distinct from new.etat) execute function gmb_prive.dossiers_evenement();

-- 12.3 Frise des demandes d'un client (PAR-13)
create or replace function gmb_prive.demandes_evenement() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.demande_evenements (demande_id, etat_avant, etat_apres, libelle_client)
  values (new.id, old.etat, new.etat, gmb_prive.libelle_etat(new.etat));
  perform gmb_prive.notifier(new.client_id, null, gmb_prive.libelle_etat(new.etat),
    format('Votre demande %s a évolué.', new.reference), '/clients/#demandes/' || new.reference, 'push');
  return null;
end $$;

create trigger gmb_demandes_evenement after update of etat on public.demandes
  for each row when (old.etat is distinct from new.etat) execute function gmb_prive.demandes_evenement();

-- 12.4 Opérations : contrôles avant paiement par carte (carte gelée, mineurs,
-- plafond hebdomadaire, solde), puis solde, MoonPoints, arrondis et coffres
create or replace function gmb_prive.operations_avant() returns trigger
language plpgsql security definer set search_path = '' as $$
declare k record; j record; v_depense numeric;
begin
  if coalesce(current_setting('gmb.import', true), 'off') = 'on' then
    return new;
  end if;
  if new.type = 'carte' and new.montant < 0 then
    if new.carte_id is not null then
      select * into k from public.cartes where id = new.carte_id;
      if k.statut <> 'active' then
        new.statut := 'refusee';
        new.motif_refus := case k.statut when 'gelee' then 'Carte gelée' when 'opposition' then 'Carte en opposition' else 'Carte inactive' end;
        return new;
      end if;
      if new.devise_origine is not null and new.devise_origine <> 'EUR' and not k.etranger then
        new.statut := 'refusee';
        new.motif_refus := 'Paiements à l''étranger désactivés';
        return new;
      end if;
    end if;
    select * into j from public.comptes_jeunes where compte_id = new.compte_id;
    if found then
      if new.mcc = any (array['7995', '5921', '5993', '6051', '6540']) then
        new.statut := 'refusee';
        new.motif_refus := 'Catégorie toujours bloquée pour les mineurs';
        return new;
      end if;
      select coalesce(-sum(montant), 0) into v_depense from public.operations
       where compte_id = new.compte_id and type = 'carte' and statut = 'comptabilisee' and montant < 0
         and date_operation > now() - interval '7 days';
      if v_depense + abs(new.montant) > j.plafond_hebdo then
        new.statut := 'refusee';
        new.motif_refus := 'Plafond hebdomadaire atteint';
        return new;
      end if;
    end if;
    if new.statut = 'comptabilisee' and (select solde from public.comptes where id = new.compte_id) + new.montant < 0 then
      new.statut := 'refusee';
      new.motif_refus := 'Solde insuffisant';
    end if;
  end if;
  return new;
end $$;

create or replace function gmb_prive.operations_apres() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_client uuid; v_taux numeric; v_points int; k record; v_arrondi numeric; v_coffre record; v_jeune record;
begin
  if coalesce(current_setting('gmb.import', true), 'off') = 'on' then
    return null;
  end if;
  if tg_op = 'INSERT' and new.statut = 'comptabilisee' then
    update public.comptes set solde = solde + new.montant where id = new.compte_id returning client_id into v_client;
  elsif tg_op = 'UPDATE' and old.statut <> 'comptabilisee' and new.statut = 'comptabilisee' then
    update public.comptes set solde = solde + new.montant where id = new.compte_id returning client_id into v_client;
  elsif tg_op = 'UPDATE' and old.statut = 'comptabilisee' and new.statut in ('annulee', 'refusee') then
    update public.comptes set solde = solde - old.montant where id = new.compte_id returning client_id into v_client;
  else
    return null;
  end if;

  if v_client is not null then
    update public.clients set derniere_operation_le = now() where id = v_client;
  end if;

  -- Coffre atteint : pleine lune et notification
  for v_coffre in select co.* from public.coffres co join public.comptes c on c.id = co.compte_id
                   where co.compte_id = new.compte_id and co.statut = 'actif' and co.objectif is not null and c.solde >= co.objectif loop
    update public.coffres set statut = 'atteint' where id = v_coffre.id;
    perform gmb_prive.notifier(v_coffre.client_id, null, 'Objectif atteint',
      format('Votre coffre « %s » a atteint son objectif. Bravo !', v_coffre.nom), null, 'push');
  end loop;

  if tg_op = 'INSERT' and new.type = 'carte' and new.montant < 0 and v_client is not null then
    -- MoonPoints selon la formule (jeux d'argent, crypto-actifs et rechargements exclus)
    select f.moonpoints_taux into v_taux from public.clients c join public.formules f on f.code = c.formule_code where c.id = v_client;
    v_points := floor(abs(new.montant) * coalesce(v_taux, 0))::int;
    if v_points >= 1 and coalesce(new.mcc, '') <> all (array['7995', '6051', '6540']) then
      insert into public.moonpoints (client_id, points, motif, operation_id, expire_le)
      values (v_client, v_points, 'Paiement · ' || new.libelle, new.id, current_date + 730);
    end if;
    -- Arrondi à l'euro supérieur, multiplié, vers le premier coffre qui l'active
    select co.* into k from public.coffres co
     where co.client_id = v_client and co.statut = 'actif' and co.arrondi_multiplicateur > 0 order by co.created_at limit 1;
    if found then
      v_arrondi := (ceil(abs(new.montant)) - abs(new.montant)) * k.arrondi_multiplicateur;
      if v_arrondi > 0 and (select solde from public.comptes where id = new.compte_id) >= v_arrondi then
        insert into public.operations (compte_id, type, libelle, montant, categorie_code, reference) values
          (new.compte_id, 'arrondi', format('Arrondi vers « %s »', k.nom), -v_arrondi, 'epargne', new.id::text),
          (k.compte_id, 'arrondi', 'Arrondi · ' || new.libelle, v_arrondi, 'epargne', new.id::text);
      end if;
    end if;
    -- Alerte au parent pour chaque paiement d'un mineur (si activée)
    select * into v_jeune from public.comptes_jeunes where compte_id = new.compte_id and alerte_paiement;
    if found then
      perform gmb_prive.notifier(v_jeune.parent_client_id, null, 'Paiement de votre enfant',
        format('%s € · %s', gmb_prive.euros(abs(new.montant)), new.libelle), null, 'push');
    end if;
  end if;
  return null;
end $$;

create trigger gmb_operations_avant before insert on public.operations
  for each row execute function gmb_prive.operations_avant();
create trigger gmb_operations_apres after insert or update of statut on public.operations
  for each row execute function gmb_prive.operations_apres();

-- 12.5 Factures : numérotation continue sans trou, totaux recalculés
create or replace function gmb_prive.factures_numero() returns trigger
language plpgsql security definer set search_path = '' as $$
declare n int; a int := extract(year from coalesce(new.date_emission, current_date))::int;
begin
  if new.numero is null or new.numero = '' then
    insert into gmb_prive.compteurs_factures (client_id, annee, dernier) values (new.client_id, a, 1)
    on conflict (client_id, annee) do update set dernier = gmb_prive.compteurs_factures.dernier + 1
    returning dernier into n;
    new.numero := format('F-%s-%s', a, lpad(n::text, 4, '0'));
  end if;
  return new;
end $$;

create or replace function gmb_prive.factures_totaux() returns trigger
language plpgsql security definer set search_path = '' as $$
declare f uuid; v_ht numeric; v_tva numeric;
begin
  if tg_op = 'DELETE' then f := old.facture_id; else f := new.facture_id; end if;
  select coalesce(sum(montant_ht), 0), coalesce(round(sum(montant_ht * taux_tva / 100), 2), 0) into v_ht, v_tva
    from public.facture_lignes where facture_id = f;
  update public.factures set total_ht = v_ht, total_tva = v_tva, total_ttc = v_ht + v_tva where id = f;
  return null;
end $$;

create trigger gmb_factures_numero before insert on public.factures
  for each row execute function gmb_prive.factures_numero();
create trigger gmb_factures_totaux after insert or update or delete on public.facture_lignes
  for each row execute function gmb_prive.factures_totaux();

-- 12.6 CMS : version en ligne remplacée seulement à la publication, après
-- relecture de la conformité (et du juridique pour un bloc réglementé)
create or replace function gmb_prive.cms_pages_publication() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_blocs jsonb;
begin
  if new.statut = 'publiee' and old.statut is distinct from 'publiee' then
    v_blocs := coalesce(new.blocs_brouillon, new.blocs);
    if new.relecteur_id is null
       or not exists (select 1 from public.collaborateur_roles where collaborateur_id = new.relecteur_id and role_code = 'conformite') then
      raise exception 'Publication impossible sans relecture de la conformité.' using errcode = '55000';
    end if;
    if new.relecteur_id = new.auteur_id then
      raise exception 'Le relecteur doit être différent de l''auteur.' using errcode = '55000';
    end if;
    if exists (select 1 from jsonb_array_elements(v_blocs) b where coalesce((b ->> 'reglemente')::boolean, false))
       and (new.approbateur_id is null
            or not exists (select 1 from public.collaborateur_roles where collaborateur_id = new.approbateur_id and role_code = 'juridique')) then
      raise exception 'Bloc réglementé : validation du service juridique requise.' using errcode = '55000';
    end if;
    if old.en_ligne then
      insert into public.cms_versions (page_id, version, blocs, statut, auteur_id)
      values (old.id, old.version, old.blocs, 'publiee', old.auteur_id) on conflict (page_id, version) do nothing;
      new.version := old.version + 1;
    end if;
    new.blocs := v_blocs;
    new.blocs_brouillon := null;
    new.en_ligne := true;
    new.publiee_le := now();
  end if;
  return new;
end $$;

create trigger gmb_cms_pages_publication before update on public.cms_pages
  for each row execute function gmb_prive.cms_pages_publication();

-- 12.7 Historique des formules (preuve des prix et taux affichés)
create or replace function gmb_prive.formules_historique() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.formules_historique (formule_code, avant, apres, modifie_par)
  values (new.code, case when tg_op = 'UPDATE' then to_jsonb(old) end, to_jsonb(new), auth.uid());
  return null;
end $$;

create trigger gmb_formules_historique after insert or update on public.formules
  for each row execute function gmb_prive.formules_historique();

-- 12.8 Grilles de crédit : contrôle bloquant du taux d'usure
create or replace function gmb_prive.grilles_usure() returns trigger
language plpgsql security definer set search_path = '' as $$
declare u numeric;
begin
  if not new.actif then
    return new;
  end if;
  select taux into u from public.taux_usure
   where categorie = new.categorie_usure and new.date_effet between valable_du and valable_au
   order by valable_du desc limit 1;
  if u is null then
    raise exception 'Aucun taux d''usure en vigueur pour la catégorie %.', new.categorie_usure using errcode = '55000';
  end if;
  if gmb_prive.taeg(new.taux_debiteur) > u then
    raise exception 'TAEG de % %% supérieur au taux d''usure de % %%.', gmb_prive.taeg(new.taux_debiteur), u using errcode = '22023';
  end if;
  return new;
end $$;

create trigger gmb_grilles_usure before insert or update on public.grilles_credit
  for each row execute function gmb_prive.grilles_usure();

-- 12.9 Paramètres de sécurité non modifiables
create or replace function gmb_prive.parametres_controle() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not old.modifiable and new.valeur <> old.valeur then
    raise exception 'Le paramètre % n''est pas modifiable (plafond réglementaire).', old.cle using errcode = '55000';
  end if;
  new.modifie_le := now();
  return new;
end $$;

create trigger gmb_parametres_controle before update on public.parametres_securite
  for each row execute function gmb_prive.parametres_controle();

-- 12.10 Incidents : délais de notification DORA calculés automatiquement
create or replace function gmb_prive.incidents_dora() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.classification = 'majeur' and new.classe_le is not null then
    new.notif_initiale_avant := least(new.classe_le + interval '4 hours', new.detecte_le + interval '24 hours');
    new.rapport_intermediaire_avant := new.notif_initiale_avant + interval '72 hours';
    new.rapport_final_avant := new.rapport_intermediaire_avant + interval '1 month';
  end if;
  return new;
end $$;

create trigger gmb_incidents_dora before insert or update on public.incidents
  for each row execute function gmb_prive.incidents_dora();

-- 12.11 Contrôles parentaux répercutés sur la carte de l'adolescent
create or replace function gmb_prive.jeunes_synchroniser() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.cartes set paiement_en_ligne = new.paiements_en_ligne, retraits = new.retraits, etranger = new.etranger
   where compte_id = new.compte_id;
  if tg_op = 'UPDATE' then
    perform gmb_prive.notifier(new.jeune_client_id, null, 'Réglages mis à jour', 'Tes réglages de carte ont été modifiés par ton parent.', null, 'push');
  end if;
  return null;
end $$;

create trigger gmb_jeunes_synchroniser after insert or update on public.comptes_jeunes
  for each row execute function gmb_prive.jeunes_synchroniser();

-- 12.12 Approbations : jamais par le demandeur lui-même
create or replace function gmb_prive.approbations_controle() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.validateur_id = (select demandeur_id from public.demandes_approbation where id = new.demande_id) then
    raise exception 'Vous ne pouvez pas valider votre propre demande.' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger gmb_approbations_controle before insert on public.approbations
  for each row execute function gmb_prive.approbations_controle();

-- 12.13 Journal d'audit chaîné (empreinte SHA-256 de la ligne précédente) et
-- impossible à modifier ou à supprimer
create or replace function gmb_prive.audit_chainer() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_prec text;
begin
  perform pg_advisory_xact_lock(424242);
  select empreinte into v_prec from public.journal_audit order by id desc limit 1;
  new.horodatage := clock_timestamp();
  new.empreinte_prec := coalesce(v_prec, 'GENESE');
  new.empreinte := encode(extensions.digest(
    new.empreinte_prec || '|' || new.horodatage::text || '|' || coalesce(new.acteur_id::text, '') || '|' || new.action || '|' ||
    new.objet_type || '|' || coalesce(new.objet_id, '') || '|' || coalesce(new.apres::text, '') || '|' || coalesce(new.motif, ''),
    'sha256'), 'hex');
  return new;
end $$;

create or replace function gmb_prive.audit_immuable() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'Le journal d''audit ne peut être ni modifié ni supprimé.' using errcode = '42501';
end $$;

create trigger gmb_audit_chainer before insert on public.journal_audit
  for each row execute function gmb_prive.audit_chainer();
create trigger gmb_audit_immuable before update or delete on public.journal_audit
  for each row execute function gmb_prive.audit_immuable();

create or replace function gmb_prive.auditer() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_ligne jsonb;
begin
  v_ligne := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  insert into public.journal_audit (acteur_id, acteur_type, action, objet_type, objet_id, avant, apres)
  values (auth.uid(), coalesce(gmb_prive.espace(), 'systeme'), tg_op, tg_table_name,
          coalesce(v_ligne ->> 'id', v_ligne ->> 'code', v_ligne ->> 'cle', v_ligne ->> 'client_id'),
          case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
          case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end);
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array['dossiers', 'dossier_pieces', 'dossier_validations', 'profils_risque', 'clients', 'cartes', 'beneficiaires',
                           'virements', 'contestations', 'alertes_lcbft', 'alertes_fraude', 'formules', 'grilles_credit',
                           'cms_textes_legaux', 'parametres_securite', 'collaborateurs', 'collaborateur_roles', 'habilitations',
                           'regles_approbation', 'approbations', 'comptes_jeunes', 'cles_api'] loop
    execute format('create trigger gmb_audit after insert or update or delete on public.%I for each row execute function gmb_prive.auditer()', t);
  end loop;
end $$;


-- =============================================================================
-- 13. VUES (les droits des tables s'appliquent : security_invoker)
-- =============================================================================
create view public.v_comptes with (security_invoker = true) as
select c.*,
       c.solde + coalesce((select sum(o.montant) from public.operations o
                            where o.compte_id = c.id and o.statut = 'en_attente' and o.montant < 0), 0) as solde_disponible,
       co.id as coffre_id, co.nom as coffre_nom, co.objectif as coffre_objectif, co.arrondi_multiplicateur,
       case when co.objectif > 0 then least(round(c.solde / co.objectif * 100), 100) end as coffre_progression
  from public.comptes c
  left join public.coffres co on co.compte_id = c.id;
comment on view public.v_comptes is 'GMB : comptes avec solde disponible et progression des coffres (PAR-01, PAR-06).';

create view public.v_solde_global with (security_invoker = true) as
select client_id, sum(solde) as solde_global, count(*) as nb_comptes
  from public.comptes
 where client_id is not null and statut = 'actif' and type in ('courant', 'livret', 'coffre', 'crypto', 'titres', 'jeune', 'pro')
 group by client_id;
comment on view public.v_solde_global is 'GMB : solde global d''un client (PAR-01).';

create view public.v_moonpoints with (security_invoker = true) as
select client_id, sum(points) as points, round(sum(points) / 100.0, 2) as valeur_euros
  from public.moonpoints
 where expire_le is null or expire_le >= current_date
 group by client_id;
comment on view public.v_moonpoints is 'GMB : solde de MoonPoints valides (PAR-07).';

create view public.v_budget_mois with (security_invoker = true) as
select b.id as budget_id, b.client_id, b.mois, b.montant, b.par_categorie,
       coalesce(-sum(o.montant) filter (where o.montant < 0), 0) as depense,
       b.montant - coalesce(-sum(o.montant) filter (where o.montant < 0), 0) as reste
  from public.budgets b
  left join public.comptes c on c.client_id = b.client_id and c.type = 'courant'
  left join public.operations o on o.compte_id = c.id and o.statut = 'comptabilisee' and o.type in ('carte', 'prelevement')
        and o.date_operation >= b.mois and o.date_operation < b.mois + interval '1 month'
 group by b.id;
comment on view public.v_budget_mois is 'GMB : budget du mois, dépensé et restant (PAR-07, lune décroissante).';

create view public.v_bo_files_dossiers with (security_invoker = true) as
select d.id, d.reference, d.type, d.segment, d.etat, d.depose_le, d.sla_echeance, d.analyste_id,
       (d.sla_echeance is not null and d.sla_echeance < now() and d.etat in ('depose', 'en_verification', 'demande_deposee', 'analyse')) as hors_delai,
       p.prenoms, coalesce(nullif(btrim(p.nom_usage), ''), p.nom_naissance) as nom, r.niveau as risque
  from public.dossiers d
  left join public.personnes p on p.id = d.personne_id
  left join public.profils_risque r on r.personne_id = d.personne_id
 where d.etat in ('depose', 'en_verification', 'incomplet', 'analyse_conformite', 'demande_deposee', 'analyse', 'offre_emise', 'delai_legal');
comment on view public.v_bo_files_dossiers is 'GMB : files de traitement et délais des dossiers (ADM-01, ADM-04).';


-- =============================================================================
-- 14. SÉCURITÉ : RLS, DROITS ET STOCKAGE
-- =============================================================================

-- 14.1 RLS : désactivée pendant le développement ; schéma interne fermé
do $$
declare r record;
begin
  for r in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind = 'r' and obj_description(c.oid, 'pg_class') like 'GMB%' loop
    -- Développement : RLS non activée (règle du projet). gmb_mode_production.sql l'active.
    null;
  end loop;
end $$;

revoke all on all tables in schema gmb_prive from public, anon, authenticated;
revoke all on all sequences in schema gmb_prive from public, anon, authenticated;

-- Coordonnées du compte de réception : le site les lit, il ne les modifie jamais
-- directement. Elles ne changent que par gmb_bo_collecte_configurer (trésorerie,
-- journal d'audit) ou par l'exploitant depuis le SQL Editor.
revoke insert, update, delete, truncate on public.parametres_banque from public, anon, authenticated;

-- 14.2 Lecture publique (vitrine, simulateurs, état des services)
create policy lecture_publique on public.formules          for select to anon, authenticated using (actif);
create policy lecture_publique on public.frais             for select to anon, authenticated using (actif);
create policy lecture_publique on public.taux_usure        for select to anon, authenticated using (true);
create policy lecture_publique on public.grilles_credit    for select to anon, authenticated using (actif and valide_conformite);
create policy lecture_publique on public.categories        for select to anon, authenticated using (true);
create policy lecture_publique on public.cms_pages         for select to anon, authenticated using (en_ligne);
create policy lecture_publique on public.cms_textes_legaux for select to anon, authenticated using (date_effet <= current_date);
create policy lecture_publique on public.cms_bandeaux      for select to anon, authenticated
  using (actif and (debut is null or debut <= now()) and (fin is null or fin > now()));
create policy lecture_publique on public.cms_faq           for select to anon, authenticated using (publie);
create policy lecture_publique on public.cms_redirections  for select to anon, authenticated using (true);
create policy lecture_publique on public.cms_medias        for select to anon, authenticated using (true);
create policy lecture_publique on public.statut_services   for select to anon, authenticated using (true);
create policy lecture_publique on public.incidents         for select to anon, authenticated using (public);
create policy lecture_publique on public.defis             for select to anon, authenticated using (actif);

-- 14.3 Back-office : lecture selon la matrice des habilitations (chapitre 18)
do $$
declare p text[];
begin
  foreach p slice 1 in array array[
    ['formules', 'ADM-03'], ['formules_historique', 'ADM-03'], ['frais', 'ADM-03'], ['taux_usure', 'ADM-03'],
    ['grilles_credit', 'ADM-03'], ['categories', 'ADM-03'],
    ['cms_pages', 'ADM-02'], ['cms_versions', 'ADM-02'], ['cms_textes_legaux', 'ADM-02'], ['cms_bandeaux', 'ADM-02'],
    ['cms_faq', 'ADM-02'], ['cms_redirections', 'ADM-02'], ['cms_medias', 'ADM-02'], ['defis', 'ADM-02'],
    ['statut_services', 'ADM-12'], ['incidents', 'ADM-12'], ['parametres_securite', 'ADM-12'], ['connexions', 'ADM-12'], ['appareils', 'ADM-12'],
    ['personnes', 'ADM-04'], ['profils_risque', 'ADM-04'], ['consentements', 'ADM-04'], ['dossiers', 'ADM-04'],
    ['dossier_evenements', 'ADM-04'], ['dossier_notes_internes', 'ADM-04'], ['dossier_pieces', 'ADM-04'], ['dossier_controles', 'ADM-04'],
    ['dossier_validations', 'ADM-04'], ['dossier_messages', 'ADM-04'], ['dossier_rendez_vous', 'ADM-04'], ['premiers_versements', 'ADM-04'],
    ['dossier_credit', 'ADM-08'], ['demandes', 'ADM-08'], ['demande_evenements', 'ADM-08'], ['credits', 'ADM-08'], ['credit_echeances', 'ADM-08'],
    ['alertes_lcbft', 'ADM-05'], ['alertes_fraude', 'ADM-06'], ['contestations', 'ADM-06'],
    ['clients', 'ADM-07'], ['comptes', 'ADM-07'], ['coffres', 'ADM-07'], ['cartes', 'ADM-07'], ['beneficiaires', 'ADM-07'],
    ['virements', 'ADM-07'], ['operations', 'ADM-07'], ['mandats_prelevement', 'ADM-07'], ['budgets', 'ADM-07'], ['moonpoints', 'ADM-07'],
    ['interets', 'ADM-07'], ['documents', 'ADM-07'], ['comptes_jeunes', 'ADM-07'], ['defis_participations', 'ADM-07'],
    ['fils_messagerie', 'ADM-09'], ['messages', 'ADM-09'], ['reclamations', 'ADM-09'],
    ['notifications', 'ADM-10'], ['modeles_notification', 'ADM-10'],
    ['entreprises', 'ADM-11'], ['entreprise_membres', 'ADM-11'], ['regles_approbation', 'ADM-11'], ['demandes_approbation', 'ADM-11'],
    ['approbations', 'ADM-11'], ['notes_de_frais', 'ADM-11'], ['cles_api', 'ADM-11'], ['webhooks', 'ADM-11'],
    ['pro_clients', 'ADM-11'], ['factures', 'ADM-11'], ['facture_lignes', 'ADM-11'],
    ['collaborateurs', 'ADM-13'], ['roles_bo', 'ADM-13'], ['modules_bo', 'ADM-13'], ['collaborateur_roles', 'ADM-13'], ['habilitations', 'ADM-13'],
    ['journal_audit', 'ADM-14']] loop
    execute format('create policy bo_lecture on public.%I for select to authenticated using (gmb_prive.bo_lecture(%L))', p[1], p[2]);
  end loop;
end $$;

-- GerMoonBank · installation de la base, partie 8 sur 8
-- Exécutez les parties dans l'ordre, chacune dans une requête vide du SQL Editor.
-- Contenu : 04_declencheurs_securite, 05_reference, 06_administration, gmb_mode_developpement.sql
-- 14.4 Back-office : écriture directe des référentiels (droit E ou A)
do $$
declare p text[];
begin
  foreach p slice 1 in array array[
    ['cms_pages', 'ADM-02'], ['cms_bandeaux', 'ADM-02'], ['cms_faq', 'ADM-02'], ['cms_redirections', 'ADM-02'], ['cms_medias', 'ADM-02'],
    ['defis', 'ADM-02'], ['formules', 'ADM-03'], ['frais', 'ADM-03'], ['grilles_credit', 'ADM-03'], ['taux_usure', 'ADM-03'],
    ['categories', 'ADM-03'], ['modeles_notification', 'ADM-10'], ['statut_services', 'ADM-12'], ['incidents', 'ADM-12'],
    ['collaborateurs', 'ADM-13'], ['collaborateur_roles', 'ADM-13'], ['habilitations', 'ADM-13'], ['regles_approbation', 'ADM-11']] loop
    execute format('create policy bo_ecriture on public.%I for all to authenticated using (gmb_prive.bo_ecriture(%L)) with check (gmb_prive.bo_ecriture(%L))',
                   p[1], p[2], p[2]);
  end loop;
end $$;

-- Textes juridiques : service juridique uniquement
create policy bo_juridique on public.cms_textes_legaux for all to authenticated
  using (gmb_prive.a_role('juridique')) with check (gmb_prive.a_role('juridique'));

-- 14.5 Espace Mon Dossier : le demandeur voit son dossier, rien d'autre
create policy demandeur on public.dossiers            for select to authenticated using (demandeur_auth = auth.uid() and gmb_prive.espace() = 'dossier');
create policy demandeur on public.dossier_credit      for select to authenticated using (gmb_prive.dossier_du_demandeur(dossier_id));
create policy demandeur on public.dossier_evenements  for select to authenticated using (gmb_prive.dossier_du_demandeur(dossier_id));
create policy demandeur on public.dossier_pieces      for select to authenticated using (gmb_prive.dossier_du_demandeur(dossier_id));
create policy demandeur on public.premiers_versements for select to authenticated using (gmb_prive.dossier_du_demandeur(dossier_id));
create policy demandeur on public.dossier_messages    for select to authenticated using (gmb_prive.dossier_du_demandeur(dossier_id));
create policy demandeur_ecrit on public.dossier_messages for insert to authenticated
  with check (gmb_prive.dossier_du_demandeur(dossier_id) and auteur = 'client' and auteur_id = auth.uid());
create policy demandeur on public.dossier_rendez_vous for select to authenticated using (gmb_prive.dossier_du_demandeur(dossier_id));
create policy demandeur_ecrit on public.dossier_rendez_vous for insert to authenticated
  with check (gmb_prive.dossier_du_demandeur(dossier_id) and statut = 'demande');
create policy proprietaire on public.consentements    for select to authenticated using (auth_user_id = auth.uid());
create policy proprietaire on public.personnes        for select to authenticated using (gmb_prive.personne_accessible(id));

-- 14.6 Espace client (particulier, parent, membre d'entreprise)
create policy titulaire on public.clients        for select to authenticated using (gmb_prive.client_visible(id));
create policy titulaire on public.comptes        for select to authenticated using (gmb_prive.compte_accessible(id));
create policy titulaire on public.coffres        for select to authenticated using (gmb_prive.compte_accessible(compte_id));
create policy titulaire on public.cartes         for select to authenticated
  using (titulaire_client_id = gmb_prive.client_courant() or gmb_prive.carte_accessible(id));
create policy titulaire on public.beneficiaires  for select to authenticated
  using (client_id = gmb_prive.client_courant() or (entreprise_id is not null and gmb_prive.membre_entreprise(entreprise_id)));
create policy titulaire_supprime on public.beneficiaires for delete to authenticated using (client_id = gmb_prive.client_courant());
create policy titulaire on public.virements      for select to authenticated using (gmb_prive.compte_accessible(compte_id));
create policy titulaire on public.operations     for select to authenticated using (gmb_prive.compte_accessible(compte_id));
create policy titulaire on public.mandats_prelevement for select to authenticated using (gmb_prive.compte_accessible(compte_id));
create policy titulaire_modifie on public.mandats_prelevement for update to authenticated
  using (gmb_prive.compte_accessible(compte_id)) with check (gmb_prive.compte_accessible(compte_id));
create policy titulaire on public.budgets        for all to authenticated
  using (client_id = gmb_prive.client_courant()) with check (client_id = gmb_prive.client_courant());
create policy titulaire on public.moonpoints     for select to authenticated using (gmb_prive.client_visible(client_id));
create policy titulaire on public.interets       for select to authenticated using (gmb_prive.compte_accessible(compte_id));
create policy titulaire on public.documents      for select to authenticated using (client_id = gmb_prive.client_courant());
create policy titulaire on public.demandes       for select to authenticated using (client_id = gmb_prive.client_courant());
create policy titulaire on public.demande_evenements for select to authenticated
  using (exists (select 1 from public.demandes d where d.id = demande_id and d.client_id = gmb_prive.client_courant()));
create policy titulaire on public.credits        for select to authenticated using (client_id = gmb_prive.client_courant());
create policy titulaire on public.credit_echeances for select to authenticated
  using (exists (select 1 from public.credits c where c.id = credit_id and c.client_id = gmb_prive.client_courant()));
create policy titulaire on public.fils_messagerie for all to authenticated
  using (client_id = gmb_prive.client_courant()) with check (client_id = gmb_prive.client_courant());
create policy titulaire on public.messages       for select to authenticated
  using (exists (select 1 from public.fils_messagerie f where f.id = fil_id and f.client_id = gmb_prive.client_courant()));
create policy titulaire_ecrit on public.messages for insert to authenticated
  with check (auteur = 'client' and auteur_id = auth.uid()
              and exists (select 1 from public.fils_messagerie f where f.id = fil_id and f.client_id = gmb_prive.client_courant()));
create policy titulaire on public.reclamations   for select to authenticated using (client_id = gmb_prive.client_courant());
create policy titulaire on public.contestations  for select to authenticated using (client_id = gmb_prive.client_courant());
create policy titulaire on public.appareils      for select to authenticated using (client_id = gmb_prive.client_courant());
create policy titulaire on public.connexions     for select to authenticated
  using (client_id = gmb_prive.client_courant() and created_at > now() - interval '90 days');
create policy destinataire on public.notifications for select to authenticated
  using (destinataire_auth = auth.uid() or client_id = gmb_prive.client_courant());
create policy destinataire_lit on public.notifications for update to authenticated
  using (destinataire_auth = auth.uid() or client_id = gmb_prive.client_courant())
  with check (destinataire_auth = auth.uid() or client_id = gmb_prive.client_courant());

-- Pro
create policy titulaire on public.pro_clients    for all to authenticated
  using (client_id = gmb_prive.client_courant()) with check (client_id = gmb_prive.client_courant());
create policy titulaire on public.factures       for select to authenticated using (client_id = gmb_prive.client_courant());
create policy titulaire_cree on public.factures  for insert to authenticated
  with check (client_id = gmb_prive.client_courant() and statut_cycle = 'brouillon'
              and exists (select 1 from public.pro_clients pc where pc.id = pro_client_id and pc.client_id = gmb_prive.client_courant()));
create policy titulaire_modifie on public.factures for update to authenticated
  using (client_id = gmb_prive.client_courant() and statut_cycle = 'brouillon')
  with check (client_id = gmb_prive.client_courant() and statut_cycle in ('brouillon', 'deposee'));
create policy titulaire on public.facture_lignes for select to authenticated
  using (exists (select 1 from public.factures f where f.id = facture_id and f.client_id = gmb_prive.client_courant()));
create policy titulaire_brouillon on public.facture_lignes for all to authenticated
  using (exists (select 1 from public.factures f where f.id = facture_id and f.client_id = gmb_prive.client_courant() and f.statut_cycle = 'brouillon'))
  with check (exists (select 1 from public.factures f where f.id = facture_id and f.client_id = gmb_prive.client_courant() and f.statut_cycle = 'brouillon'));

-- Business
create policy membre on public.entreprises            for select to authenticated using (gmb_prive.membre_entreprise(id));
create policy membre on public.entreprise_membres     for select to authenticated using (gmb_prive.membre_entreprise(entreprise_id));
create policy administrateur on public.entreprise_membres for all to authenticated
  using (gmb_prive.role_entreprise(entreprise_id) = 'administrateur') with check (gmb_prive.role_entreprise(entreprise_id) = 'administrateur');
create policy membre on public.regles_approbation     for select to authenticated using (gmb_prive.membre_entreprise(entreprise_id));
create policy administrateur on public.regles_approbation for all to authenticated
  using (gmb_prive.role_entreprise(entreprise_id) = 'administrateur') with check (gmb_prive.role_entreprise(entreprise_id) = 'administrateur');
create policy membre on public.demandes_approbation   for select to authenticated using (gmb_prive.membre_entreprise(entreprise_id));
create policy membre on public.approbations           for select to authenticated
  using (exists (select 1 from public.demandes_approbation d where d.id = demande_id and gmb_prive.membre_entreprise(d.entreprise_id)));
create policy membre on public.notes_de_frais         for select to authenticated
  using (client_id = gmb_prive.client_courant()
         or gmb_prive.role_entreprise(entreprise_id) in ('administrateur', 'responsable_financier', 'comptable'));
create policy administrateur on public.cles_api       for all to authenticated
  using (gmb_prive.role_entreprise(entreprise_id) = 'administrateur') with check (gmb_prive.role_entreprise(entreprise_id) = 'administrateur');
create policy administrateur on public.webhooks       for all to authenticated
  using (gmb_prive.role_entreprise(entreprise_id) = 'administrateur') with check (gmb_prive.role_entreprise(entreprise_id) = 'administrateur');

-- Jeunes
create policy famille on public.comptes_jeunes        for select to authenticated
  using (gmb_prive.client_courant() in (parent_client_id, second_parent_client_id, jeune_client_id));
create policy famille on public.defis_participations  for select to authenticated using (gmb_prive.client_visible(client_id));

-- 14.7 Droits d'exécution des fonctions
revoke execute on all functions in schema gmb_prive from public;
grant execute on function
  gmb_prive.espace(), gmb_prive.client_courant(), gmb_prive.est_collaborateur(), gmb_prive.a_role(text),
  gmb_prive.droit_bo(text, text[]), gmb_prive.bo_lecture(text), gmb_prive.bo_ecriture(text), gmb_prive.bo_decision(text),
  gmb_prive.dossier_du_demandeur(uuid), gmb_prive.membre_entreprise(uuid), gmb_prive.role_entreprise(uuid),
  gmb_prive.compte_accessible(uuid), gmb_prive.carte_accessible(uuid), gmb_prive.client_visible(uuid),
  gmb_prive.personne_accessible(uuid), gmb_prive.luhn_valide(text), gmb_prive.iban_valide(text), gmb_prive.normaliser_nom(text)
to anon, authenticated, service_role;

do $$
declare r record;
  publiques text[] := array['gmb_simuler_credit', 'gmb_simuler_epargne', 'gmb_version'];
  serveur   text[] := array['gmb_clavier_nouveau', 'gmb_clavier_verifier', 'gmb_clavier_decoder', 'gmb_activer_client',
                            'gmb_appareil_enregistrer', 'gmb_appareil_reconnaitre', 'gmb_calculer_interets',
                            'gmb_expirer_approbations', 'gmb_purger_prospects', 'gmb_publier_planifiees', 'gmb_code_secret_reinitialiser', 'gmb_code_secret_controler', 'gmb_executer_programmes', 'gmb_prelever_echeances', 'gmb_prelever_cotisations'];
begin
  for r in select p.oid::regprocedure as f, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'gmb\_%' loop
    execute 'revoke execute on function ' || r.f || ' from public, anon, authenticated';
    if r.proname = any (publiques) then
      execute 'grant execute on function ' || r.f || ' to anon, authenticated, service_role';
    elsif r.proname = any (serveur) then
      execute 'grant execute on function ' || r.f || ' to service_role';
    else
      execute 'grant execute on function ' || r.f || ' to authenticated, service_role';
    end if;
  end loop;
end $$;

-- 14.8 Stockage des fichiers (Supabase Storage)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('gmb-pieces', 'gmb-pieces', false, 10485760, array['application/pdf', 'image/jpeg', 'image/png', 'image/heic']),
  ('gmb-documents', 'gmb-documents', false, 10485760, array['application/pdf']),
  ('gmb-justificatifs', 'gmb-justificatifs', false, 10485760, array['application/pdf', 'image/jpeg', 'image/png', 'image/heic']),
  ('gmb-medias', 'gmb-medias', true, 5242880, array['image/jpeg', 'image/png', 'image/webp', 'image/avif', 'image/svg+xml'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit,
                               allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "gmb pieces depot" on storage.objects;
drop policy if exists "gmb pieces lecture" on storage.objects;
drop policy if exists "gmb documents lecture" on storage.objects;
drop policy if exists "gmb justificatifs depot" on storage.objects;
drop policy if exists "gmb justificatifs lecture" on storage.objects;
drop policy if exists "gmb medias ecriture" on storage.objects;
drop policy if exists "gmb medias modification" on storage.objects;
drop policy if exists "gmb medias suppression" on storage.objects;

-- Pièces du dossier : {auth.uid}/{dossier}/{fichier}, déposées depuis Mon Dossier
create policy "gmb pieces depot" on storage.objects for insert to authenticated
  with check (bucket_id = 'gmb-pieces' and (storage.foldername(name))[1] = auth.uid()::text and gmb_prive.espace() = 'dossier');
create policy "gmb pieces lecture" on storage.objects for select to authenticated
  using (bucket_id = 'gmb-pieces' and ((storage.foldername(name))[1] = auth.uid()::text or gmb_prive.bo_lecture('ADM-04')));
-- Documents du client : {client_id}/{fichier}
create policy "gmb documents lecture" on storage.objects for select to authenticated
  using (bucket_id = 'gmb-documents' and ((storage.foldername(name))[1] = gmb_prive.client_courant()::text or gmb_prive.bo_lecture('ADM-07')));
-- Justificatifs d'opérations et notes de frais : {auth.uid}/{fichier}
create policy "gmb justificatifs depot" on storage.objects for insert to authenticated
  with check (bucket_id = 'gmb-justificatifs' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "gmb justificatifs lecture" on storage.objects for select to authenticated
  using (bucket_id = 'gmb-justificatifs' and ((storage.foldername(name))[1] = auth.uid()::text or gmb_prive.bo_lecture('ADM-11')));
-- Médias de la vitrine (lecture publique, écriture par le contenu)
create policy "gmb medias ecriture" on storage.objects for insert to authenticated
  with check (bucket_id = 'gmb-medias' and gmb_prive.bo_ecriture('ADM-02'));
create policy "gmb medias modification" on storage.objects for update to authenticated
  using (bucket_id = 'gmb-medias' and gmb_prive.bo_ecriture('ADM-02'));
create policy "gmb medias suppression" on storage.objects for delete to authenticated
  using (bucket_id = 'gmb-medias' and gmb_prive.bo_ecriture('ADM-02'));


-- =============================================================================
-- 15. DONNÉES DE RÉFÉRENCE (cahier des charges v2.1, chapitres 3, 6, 12 et 18)
-- =============================================================================
insert into public.formules (code, segment, nom, accroche, prix_mensuel, prix_ht, carte, retraits_hors_zone_mois, change_sans_frais_mois,
                             taux_livret, moonpoints_taux, coffres_max, cartes_physiques, cartes_virtuelles, utilisateurs_max,
                             operations_incluses, assurances, services, badge, ordre) values
  ('luna',  'particulier', 'Luna',  'L''essentiel du quotidien, sans frais cachés.', 0,     false, 'Débit', 200,  1000, 2.00, 0,    3,    1, 1,  null, null, '{}', '{support_application}', null, 1),
  ('halo',  'particulier', 'Halo',  'Pour voyager léger et épargner mieux.',          4.90,  false, 'Débit, design au choix', 400, 3000, 2.50, 0.25, 10, 1, 3, null, null, '{}', '{support_prioritaire}', null, 2),
  ('orbit', 'particulier', 'Orbit', 'Assurances voyage et achats incluses.',          9.90,  false, 'Débit premium', 800, 8000, 3.25, 0.50, null, 1, 5, null, null, '{voyage,achats}', '{support_prioritaire}', 'Le plus choisi', 3),
  ('eclipse','particulier','Éclipse','Carte métal et protection étendue.',            16.90, false, 'Métal', 1500, null, 4.00, 0.75, null, 1, 10, null, null,
   '{voyage,achats,annulation,location_vehicule,telephone}', '{ligne_dediee}', null, 4),
  ('zenith','particulier', 'Zénith','Le meilleur taux et un conseiller dédié.',        49.00, false, 'Métal', 3000, null, 5.25, 1.00, null, 1, 20, null, null,
   '{voyage,achats,annulation,location_vehicule,telephone,famille}', '{conseiller_dedie,salons_aeroport}', null, 5),
  ('pro_solo',       'pro',      'Pro Solo',        'Facturer, encaisser et provisionner au même endroit.', 9,   true, 'Débit Pro', null, null, null, 0, null, 1,   5,    1,    100,   '{}', '{facturation_electronique,provisions,export_comptable}', null, 10),
  ('pro_plus',       'pro',      'Pro Plus',        'Liens de paiement et relances automatiques.',          19,  true, 'Débit Pro', null, null, null, 0, null, 2,   20,   2,    300,   '{}', '{liens_paiement,relances,comptable_invite}', null, 11),
  ('business_start', 'business', 'Business Start',  'Rôles, approbations et notes de frais.',               29,  true, 'Business',  null, null, null, 0, null, 5,   20,   5,    500,   '{}', '{roles,approbations,notes_de_frais}', null, 20),
  ('business_growth','business', 'Business Growth', 'Approbations à plusieurs niveaux et API en lecture.',  79,  true, 'Business',  null, null, null, 0, null, 20,  100,  20,   2000,  '{}', '{approbations_multiniveaux,lecture_justificatifs,api_lecture}', null, 21),
  ('business_scale', 'business', 'Business Scale',  'API complète, webhooks et support dédié.',             199, true, 'Business',  null, null, null, 0, null, 100, 1000, null, 10000, '{}', '{api_complete,webhooks,virements_groupes,support_dedie}', null, 22);

insert into public.frais (code, libelle, pourcentage, montant, minimum, conditions) values
  ('retrait_hors_zone', 'Retrait hors zone euro au-delà de la franchise', 2.000, null, 1.00, 'Franchise mensuelle selon la formule'),
  ('change',            'Paiement en devise au-delà de la franchise',     0.500, null, null, 'Écart avec le taux de référence de la BCE affiché avant paiement'),
  ('majoration_week_end','Majoration du change le week-end',              1.000, null, null, 'Marchés fermés, du vendredi soir au dimanche soir'),
  ('operation_sup_pro', 'Opération SEPA au-delà du forfait Pro ou Business', null, 0.20, null, 'Montant hors taxes');

-- Valeur indicative : à mettre à jour chaque trimestre avec le taux publié au Journal officiel
insert into public.taux_usure (categorie, taux, valable_du, valable_au, source) values
  ('conso_plus_6000', 8.500, '2026-01-01', '2027-12-31', 'Taux d''usure : à vérifier et mettre à jour chaque trimestre (publication de la Banque de France)');

insert into public.grilles_credit (objet, montant_min, montant_max, duree_min, duree_max, taux_debiteur, valide_conformite) values
  ('tous', 1000, 50000, 6,  24, 4.900, true),
  ('tous', 1000, 50000, 25, 48, 5.750, true),   -- exemple de référence : 10 000 € sur 48 mois → 233,71 €
  ('tous', 1000, 50000, 49, 84, 6.250, true);

insert into public.categories (code, libelle, icone, couleur, ordre) values
  ('alimentation', 'Courses', 'shopping-cart', 'teal', 1), ('restaurants', 'Restaurants', 'utensils', 'rose', 2),
  ('transports', 'Transports', 'train-front', 'violet', 3), ('logement', 'Logement', 'house', 'violet', 4),
  ('loisirs', 'Loisirs', 'ticket', 'rose', 5), ('sante', 'Santé', 'heart-pulse', 'teal', 6),
  ('shopping', 'Shopping', 'shopping-bag', 'rose', 7), ('voyages', 'Voyages', 'plane', 'teal', 8),
  ('abonnements', 'Abonnements', 'repeat', 'violet', 9), ('salaire', 'Revenus', 'banknote', 'teal', 10),
  ('epargne', 'Épargne', 'piggy-bank', 'teal', 11), ('impots', 'Impôts', 'landmark', 'violet', 12),
  ('transferts', 'Virements', 'arrow-left-right', 'violet', 13), ('frais', 'Frais bancaires', 'receipt', 'violet', 14),
  ('autres', 'Autres', 'circle-dot', 'violet', 15);

insert into public.cms_textes_legaux (code, titre, contenu, entite) values
  ('LEG-FGDR-02', 'Garantie des dépôts',
   'Vous pouvez y aller en toute confiance : vos dépôts sont couverts par la garantie du FGDR jusqu''à 100 000 € par déposant et par établissement, auprès de [établissement partenaire].', '[établissement partenaire]'),
  ('LEG-CREDIT-01', 'Mention obligatoire du crédit',
   'Un crédit vous engage et doit être remboursé. Vérifiez vos capacités de remboursement avant de vous engager.', null),
  ('LEG-CREDIT-EX-01', 'Exemple représentatif du prêt personnel',
   'Exemple représentatif : pour un prêt personnel de 10 000 € sur 48 mois au taux débiteur fixe de 5,75 %, soit un TAEG fixe de 5,90 %, vous remboursez 48 mensualités de 233,71 € (hors assurance facultative). Montant total dû : 11 218,08 €. Coût total du crédit : 1 218,08 €. Offre soumise à conditions, sous réserve d''acceptation de votre dossier par le prêteur. Délai de rétractation de 14 jours.', null),
  ('LEG-CRYPTO-01', 'Avertissement crypto-actifs',
   'Les crypto-actifs sont volatils : vous pouvez perdre tout ou partie de votre investissement. Ils ne sont pas couverts par la garantie des dépôts. Service réservé aux majeurs, fourni par un prestataire agréé MiCA.', null),
  ('LEG-LIVRET-01', 'Taux du Livret GMB', 'Taux annuels bruts, révisables, avant prélèvements fiscaux et sociaux.', null),
  ('LEG-MARQUE-01', 'Identité de la marque',
   'GerMoonBank est une marque de The Hub of Inspiration of Soccer (RCCM RB/ABC/24 A 111814). Services bancaires fournis par [établissement partenaire], agréé par l''ACPR.', 'The Hub of Inspiration of Soccer'),
  ('LEG-PROSPECTS-01', 'Données des demandeurs',
   'Les données de votre demande sont conservées 12 mois si elle n''aboutit pas, puis supprimées ou anonymisées à des fins statistiques, sauf obligation légale. Les échanges avec nos conseillers peuvent être enregistrés.', null),
  ('LEG-COOKIES-01', 'Cookies',
   'Nous utilisons des cookies pour faire fonctionner le site et, avec votre accord, pour mesurer son audience. Vous pouvez accepter, refuser ou personnaliser vos choix à tout moment.', null);

insert into public.cms_bandeaux (niveau, message, lien_libelle, lien_url, conditions_url) values
  ('promotion', 'Livret GMB : jusqu''à 5,25 % brut par an avec la formule Zénith.', 'Voir les conditions',
   '/particuliers/epargne/', '/particuliers/epargne/#conditions');

insert into public.cms_pages (ecran, slug, titre, titre_seo, description_seo, blocs, statut, en_ligne, publiee_le) values
  ('VIT-01', '', 'Accueil', 'GerMoonBank — La banque qui veille sur votre argent',
   'Compte, carte, épargne rémunérée chaque jour, bourse et crédit dans une seule application sécurisée.',
   '[{"type":"heros","titre":"La banque qui veille sur votre argent, jour et nuit.","sous_titre":"Compte, carte, épargne rémunérée chaque jour, bourse et crédit dans une seule application.","boutons":[{"libelle":"Ouvrir un compte","lien":"/souscrire/"},{"libelle":"Découvrir les formules","lien":"/particuliers/tarifs/"}]},
     {"type":"confiance","elements":["Virements instantanés gratuits","Carte Luna à 0 €","Épargne rémunérée","Service client 7 j/7"]},
     {"type":"segments"},{"type":"epargne","formule":"zenith","montant":10000},{"type":"securite"},{"type":"formules"},
     {"type":"faq","rubrique":"accueil"},{"type":"mentions","codes":["LEG-FGDR-02","LEG-MARQUE-01"],"reglemente":true}]',
   'publiee', true, now()),
  ('VIT-11', 'particuliers/epargne', 'Épargne et Livret GMB', 'Livret GMB : intérêts versés chaque jour',
   'Faites grandir votre épargne chaque jour : intérêts calculés et versés quotidiennement, argent disponible à tout moment.',
   '[{"type":"heros","titre":"Faites grandir votre épargne, chaque jour.","sous_titre":"Intérêts calculés et versés quotidiennement, argent disponible à tout moment."},
     {"type":"taux_formules","source":"catalogue"},{"type":"simulateur_epargne","montant":10000,"formule":"zenith"},
     {"type":"coffres"},{"type":"faq","rubrique":"epargne"},{"type":"mentions","codes":["LEG-LIVRET-01","LEG-FGDR-02"],"reglemente":true}]',
   'publiee', true, now()),
  ('VIT-15', 'particuliers/credits', 'Crédits et simulateur', 'Prêt personnel : simulez votre mensualité',
   'De 1 000 € à 50 000 € sur 6 à 84 mois, à taux fixe et sans frais de dossier. Réponse de principe immédiate.',
   '[{"type":"heros","titre":"Un projet ? Simulez votre mensualité en toute transparence."},
     {"type":"simulateur_credit","montant":10000,"duree":48},{"type":"mentions","codes":["LEG-CREDIT-01","LEG-CREDIT-EX-01"],"reglemente":true}]',
   'publiee', true, now());

insert into public.cms_faq (rubrique, question, reponse, ordre) values
  ('accueil', 'Quelle différence entre Mon Dossier et l''Espace client ?',
   'L''Espace Mon Dossier sert à suivre une demande d''ouverture de compte ou de crédit, avec votre e-mail et un mot de passe. L''Espace client donne accès à vos comptes, avec votre identifiant bancaire, votre code secret et votre téléphone de confiance.', 1),
  ('accueil', 'Combien de temps pour ouvrir un compte ?',
   'Environ 8 minutes de saisie. Nous vérifions votre dossier sous 48 heures ouvrées et vous suivez chaque étape dans l''Espace Mon Dossier.', 2),
  ('accueil', 'Mon argent est-il protégé ?',
   'Vos dépôts sont couverts par la garantie du FGDR jusqu''à 100 000 € par déposant et par établissement. Les crypto-actifs ne sont pas couverts.', 3),
  ('epargne', 'Quand mes intérêts sont-ils versés ?', 'Chaque jour : ils sont calculés sur votre solde de fin de journée et versés sur votre Livret GMB.', 1),
  ('epargne', 'Puis-je retirer mon argent à tout moment ?', 'Oui, votre épargne est disponible immédiatement vers votre compte courant GerMoonBank.', 2),
  ('securite', 'GerMoonBank peut-il me demander mon code secret ?',
   'Jamais : ni par téléphone, ni par e-mail, ni par SMS. En cas de doute, raccrochez et contactez-nous depuis l''application.', 1);

insert into public.statut_services (service, libelle) values
  ('connexion', 'Connexion à l''Espace client'), ('cartes', 'Paiements par carte'), ('virements', 'Virements'),
  ('application', 'Application mobile'), ('mon_dossier', 'Espace Mon Dossier'), ('api', 'API Business');

insert into public.roles_bo (code, libelle) values
  ('conformite', 'Conformité'), ('analyste_kyc', 'Analyste KYC'), ('conseiller', 'Conseiller'), ('fraude', 'Fraude'),
  ('credit', 'Crédit'), ('marketing', 'Contenu et marketing'), ('juridique', 'Juridique'), ('finance', 'Finance'),
  ('securite', 'Sécurité'), ('audit', 'Audit interne'), ('direction', 'Direction');

insert into public.modules_bo (code, libelle, adresse) values
  ('ADM-01', 'Tableau de bord opérationnel', '/bo/'),            ('ADM-02', 'CMS et bibliothèque juridique', '/bo/cms'),
  ('ADM-03', 'Catalogue, tarifs et taux', '/bo/catalogue'),      ('ADM-04', 'Dossiers et KYC', '/bo/dossiers'),
  ('ADM-05', 'LCB-FT et filtrage', '/bo/lcb-ft'),                ('ADM-06', 'Fraude, litiges et contestations', '/bo/fraude'),
  ('ADM-07', 'Clients 360°', '/bo/clients'),                     ('ADM-08', 'Crédits', '/bo/credits'),
  ('ADM-09', 'Support, messagerie et réclamations', '/bo/support'), ('ADM-10', 'Notifications et modèles', '/bo/notifications'),
  ('ADM-11', 'Pro, Business et API', '/bo/entreprises'),         ('ADM-12', 'Sécurité et authentification', '/bo/securite'),
  ('ADM-13', 'Habilitations', '/bo/habilitations'),              ('ADM-14', 'Journal d''audit', '/bo/audit'),
  ('ADM-15', 'Reporting et pilotage', '/bo/reporting'),          ('ADM-16', 'Trésorerie et comptabilité', '/bo/tresorerie');

-- Matrice des habilitations (chapitre 18) : L lecture, E écriture, V validation, A administration, - aucun accès
do $$
declare
  v_roles text[] := array['conformite', 'analyste_kyc', 'conseiller', 'fraude', 'credit', 'marketing', 'juridique', 'finance', 'securite', 'audit', 'direction'];
  v_ligne text; v_cases text[]; i int;
begin
  foreach v_ligne in array array[
    'ADM-01 L L L L L L L L L L L', 'ADM-02 V - - - - E V - - L L', 'ADM-03 V - - - E E L E - L L', 'ADM-04 V E L L - - - - - L L',
    'ADM-05 E L - L - - - - - L L', 'ADM-06 L - L E - - - L L L L', 'ADM-07 L L E L L - - L - L L', 'ADM-08 L - L - E - - L - L L',
    'ADM-09 L - E L L - L - - L L', 'ADM-10 V - - - - E V - - L L', 'ADM-11 L E E L - - - L L L L', 'ADM-12 L - - L - - - - A L L',
    'ADM-13 L - - - - - - - A L V', 'ADM-14 L - - L - - L - L L L', 'ADM-15 L L L L L L L L L L L', 'ADM-16 L - - - - - - E - L L'] loop
    v_cases := regexp_split_to_array(v_ligne, '\s+');
    for i in 1..array_length(v_roles, 1) loop
      if v_cases[i + 1] <> '-' then
        insert into public.habilitations (module_code, role_code, droit) values (v_cases[1], v_roles[i], v_cases[i + 1]);
      end if;
    end loop;
  end loop;
end $$;

insert into public.parametres_securite (cle, valeur, valeur_min, valeur_max, unite, description, modifiable) values
  ('grille_ttl_secondes',            120, 60, 180,  'secondes',   'Validité d''une grille du clavier virtuel', true),
  ('echecs_avant_blocage',           3,   1,  5,    'essais',     'Échecs consécutifs avant blocage temporaire (5 au plus, DSP2)', true),
  ('blocage_minutes',                30,  15, 1440, 'minutes',    'Durée du blocage temporaire', true),
  ('echecs_24h_blocage_definitif',   6,   3,  10,   'essais',     'Échecs sur 24 heures avant blocage complet', true),
  ('inactivite_minutes',             5,   1,  5,    'minutes',    'Déconnexion après inactivité (5 minutes au plus, DSP2)', false),
  ('alerte_inactivite_minutes',      4,   1,  4,    'minutes',    'Alerte avant la déconnexion', true),
  ('session_max_minutes',            60,  15, 120,  'minutes',    'Durée maximale d''une session', true),
  ('masquage_carte_secondes',        30,  10, 60,   'secondes',   'Masquage automatique des données de carte', true),
  ('nouveau_beneficiaire_plafond',   1000, 0, 5000, 'euros',      'Plafond d''un nouveau bénéficiaire', true),
  ('nouveau_beneficiaire_heures',    72,  24, 168,  'heures',     'Durée du plafond d''un nouveau bénéficiaire', true),
  ('mon_dossier_inactivite_minutes', 15,  5,  30,   'minutes',    'Déconnexion de l''Espace Mon Dossier', true),
  ('mon_dossier_tentatives',         5,   3,  10,   'essais',     'Tentatives de connexion à Mon Dossier par 15 minutes', true),
  ('mot_de_passe_longueur_min',      12,  12, 64,   'caractères', 'Longueur minimale du mot de passe Mon Dossier', true),
  ('code_activation_heures',         72,  24, 72,   'heures',     'Validité du code d''activation', true),
  ('approbation_expiration_jours',   7,   1,  30,   'jours',      'Expiration d''une demande d''approbation', true),
  ('complement_delai_jours',         30,  7,  60,   'jours',      'Délai accordé pour fournir un complément', true),
  ('brouillon_abandon_jours',        30,  7,  90,   'jours',      'Clôture d''un brouillon inactif', true),
  ('incomplet_abandon_jours',        60,  30, 120,  'jours',      'Clôture d''un dossier incomplet sans réponse', true),
  ('prospects_conservation_mois',    12,  12, 60,   'mois',       'Conservation des données d''un demandeur non client', true);

insert into public.modeles_notification (code, canal, sujet, contenu, variables) values
  ('MSG-ACCES-01', 'email', 'Votre code de vérification', 'Votre code de vérification GerMoonBank : {{code}}. Il est valable 10 minutes.', '{code}'),
  ('MSG-RELANCE-01', 'email', 'Votre demande vous attend',
   'Bonjour {{prenom}}, votre demande {{reference}} est enregistrée. Reprenez-la quand vous le souhaitez depuis l''Espace Mon Dossier.', '{prenom,reference}'),
  ('MSG-DEPOT-01', 'email', 'Votre dossier est déposé',
   'Bonjour {{prenom}}, nous avons bien reçu votre dossier {{reference}}. Nous vérifions vos pièces sous 48 heures ouvrées.', '{prenom,reference}'),
  ('MSG-KYC-01', 'message_dossier', 'Pièce illisible',
   'Bonjour, la pièce transmise n''est pas lisible. Merci d''en déposer une nouvelle photo, nette et entière, dans votre Espace Mon Dossier.', '{}'),
  ('MSG-KYC-04', 'message_dossier', 'Justificatif de domicile',
   'Bonjour, merci pour votre demande. Il nous manque un justificatif de domicile récent pour poursuivre : le document transmis date de plus de 3 mois. Déposez une facture d''énergie ou de téléphone, un avis d''imposition ou une quittance de loyer émise par un professionnel.', '{}'),
  ('MSG-ACCORD-01', 'email', 'Votre compte est ouvert',
   'Bonne nouvelle {{prenom}} : votre compte est ouvert. Retrouvez votre identifiant bancaire dans l''Espace Mon Dossier, puis activez votre accès : un code vous sera envoyé par e-mail.', '{prenom}'),
  ('MSG-REFUS-01', 'message_dossier', 'Votre demande',
   'Après étude de votre dossier, nous ne pouvons pas donner une suite favorable à votre demande. Votre premier versement vous est remboursé sous 5 jours ouvrés.', '{}'),
  ('MSG-BENEF-01', 'push', 'Nouveau bénéficiaire', '{{nom}} a été ajouté à vos bénéficiaires. Si ce n''était pas vous, contactez-nous immédiatement.', '{nom}'),
  ('MSG-CONNEXION-BLOQUEE', 'email', 'Accès bloqué par sécurité',
   'Plusieurs codes erronés ont été saisis sur votre accès. Si ce n''était pas vous, contactez-nous depuis l''application.', '{}'),
  ('MSG-RECLAMATION-AR', 'email', 'Nous avons reçu votre réclamation',
   'Votre réclamation {{reference}} est enregistrée. Nous vous répondrons au plus tard le {{date_limite}}.', '{reference,date_limite}');

insert into public.defis (code, titre, description, objectif, recompense) values
  ('mettre_5_euros', 'Mets 5 € de côté avant dimanche', 'Verse au moins 5 € dans un de tes coffres cette semaine.', 5, 20),
  ('trois_jours_sans_achat', 'Trois jours sans achat plaisir', 'Évite les achats non prévus pendant trois jours.', null, 30),
  ('objectif_atteint', 'Atteins ton premier objectif', 'Remplis complètement un de tes coffres.', null, 100);


-- Coordonnées de collecte : à renseigner avec gmb_prive.configurer_collecte(...)
insert into public.parametres_banque (cle, valeur, libelle) values
  ('collecte_titulaire', '', 'Titulaire du compte de collecte'),
  ('collecte_iban', '', 'IBAN du compte de collecte'),
  ('collecte_bic', '', 'BIC du compte de collecte'),
  ('collecte_banque', '', 'Banque du compte de collecte')
on conflict (cle) do nothing;

-- =============================================================================
-- 15. ADMINISTRATION : premier administrateur et compte de collecte
-- =============================================================================

-- Premier administrateur du back-office. L'utilisateur doit exister dans
-- Authentication → Users (Add user, Auto Confirm User). Il reçoit tous les rôles.
--   select gmb_prive.creer_administrateur('vous@exemple.fr', 'Votre nom');
create or replace function gmb_prive.creer_administrateur(p_email text, p_nom text default null)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_id uuid; v_email text := lower(trim(coalesce(p_email, '')));
begin
  select id into v_id from auth.users where lower(email) = v_email;
  if v_id is null then
    raise exception 'Créez d''abord l''utilisateur % dans Authentication → Users (Add user, Auto Confirm User).', v_email;
  end if;
  update auth.users set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"espace": "backoffice"}'::jsonb where id = v_id;
  insert into public.collaborateurs (id, nom, email)
  values (v_id, coalesce(nullif(trim(coalesce(p_nom, '')), ''), split_part(v_email, '@', 1)), v_email)
  on conflict (id) do update set actif = true, nom = excluded.nom, email = excluded.email;
  insert into public.collaborateur_roles (collaborateur_id, role_code)
  select v_id, code from public.roles_bo on conflict do nothing;
  return jsonb_build_object('administrateur', v_email,
    'roles', (select count(*) from public.collaborateur_roles where collaborateur_id = v_id));
end $$;

-- Compte bancaire réel de GerMoonBank qui reçoit les premiers versements et les
-- virements destinés aux clients :
--   select gmb_prive.configurer_collecte('Titulaire', 'FR76 ...', 'BIC', 'Nom de la banque');
create or replace function gmb_prive.configurer_collecte(p_titulaire text, p_iban text, p_bic text, p_banque text)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_iban text := upper(replace(coalesce(p_iban, ''), ' ', ''));
begin
  if not gmb_prive.iban_valide(v_iban) then
    raise exception 'IBAN invalide : vérifiez-le.' using errcode = '22023';
  end if;
  if coalesce(trim(p_titulaire), '') = '' then
    raise exception 'Indiquez le titulaire du compte.' using errcode = '22023';
  end if;
  insert into public.parametres_banque (cle, valeur, libelle) values
    ('collecte_titulaire', trim(p_titulaire), 'Titulaire du compte de collecte'),
    ('collecte_iban', v_iban, 'IBAN du compte de collecte'),
    ('collecte_bic', upper(trim(coalesce(p_bic, ''))), 'BIC du compte de collecte'),
    ('collecte_banque', trim(coalesce(p_banque, '')), 'Banque du compte de collecte')
  on conflict (cle) do update set valeur = excluded.valeur, modifie_le = now();
  return jsonb_build_object('titulaire', trim(p_titulaire), 'iban', v_iban);
end $$;

revoke execute on function gmb_prive.creer_administrateur(text, text) from public, anon, authenticated, service_role;
revoke execute on function gmb_prive.configurer_collecte(text, text, text, text) from public, anon, authenticated, service_role;
-- =============================================================================
-- GerMoonBank (GMB) · supabase/gmb_mode_developpement.sql
-- MODE DÉVELOPPEMENT : désactive les règles d'accès (RLS) sur toutes les tables.
-- -----------------------------------------------------------------------------
-- Supabase → SQL Editor → coller → Run. Rejouable sans risque.
-- Les règles (policies) restent enregistrées dans la base : elles sont seulement
-- mises en pause. gmb_mode_production.sql les réactive toutes d'un coup.
-- ATTENTION : sans RLS, toute personne qui dispose de la clé publiable (présente dans
-- le site public) peut lire et modifier les tables. N'y mettez que vos propres essais,
-- jamais les données de vrais clients.
-- =============================================================================
do $$
declare
  r record;
  n int := 0;
begin
  for r in select schemaname, tablename from pg_tables where schemaname in ('public', 'gmb_prive') and rowsecurity loop
    execute format('alter table %I.%I disable row level security', r.schemaname, r.tablename);
    n := n + 1;
  end loop;
  raise notice 'Mode développement : RLS désactivée sur % table(s).', n;
end
$$;

-- Droits d'accès du site (déjà accordés par défaut par Supabase ; rappelés ici pour
-- que le mode développement fonctionne dans tous les cas)
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to anon, authenticated;
grant usage, select on all sequences in schema public to anon, authenticated;

-- Exception : les coordonnées du compte qui reçoit les virements restent en lecture
-- seule pour le site. Elles ne changent que par le back-office (trésorerie, avec trace
-- au journal d'audit) ou par l'exploitant depuis le SQL Editor.
revoke insert, update, delete, truncate on public.parametres_banque from public, anon, authenticated;

select schemaname as schema, count(*) as tables, count(*) filter (where rowsecurity) as tables_encore_avec_rls
  from pg_tables where schemaname in ('public', 'gmb_prive') group by schemaname order by schemaname;
