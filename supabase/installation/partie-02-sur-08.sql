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
