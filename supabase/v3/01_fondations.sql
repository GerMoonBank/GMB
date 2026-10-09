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
