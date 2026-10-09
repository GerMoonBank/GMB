

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
