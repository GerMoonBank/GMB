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
