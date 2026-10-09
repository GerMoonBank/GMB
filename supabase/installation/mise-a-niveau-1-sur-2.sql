-- GerMoonBank · mise à niveau de la base, bloc 1 sur 2
-- =============================================================================
-- GerMoonBank (GMB) · supabase/gmb_mise_a_niveau.sql
-- MISE À NIVEAU D'UNE BASE DÉJÀ INSTALLÉE — version 20261009
-- -----------------------------------------------------------------------------
-- Pour une base GerMoonBank version 3 déjà en service (installée au lot E2a ou après).
-- Ne supprime rien, ne remet rien à zéro, et peut être exécutée plusieurs fois sans
-- risque : Supabase › SQL Editor › nouvelle requête vide › coller › Run.
-- Elle apporte, dans l'ordre :
--   1. la messagerie et les rendez-vous des clients (lot E2b) ;
--   2. les paramètres du client et la fermeture du compte (lot E2c) ;
--   3. les correctifs : nom d'usage vide, reprise d'une demande en cours, premier
--      versement, identifiant réaffichable, contrôle du code secret, décisions du
--      back-office expliquées ;
--   4. l'exploitation : version de la base, compte de réception réglé depuis le
--      back-office, état de l'installation ;
--   5. les cartes (commande, émission, activation) et l'IBAN attribué à un compte ;
--   6. les droits et la correction des données déjà enregistrées.
-- La dernière ligne du résultat doit afficher : version_base = 20261009.
-- Une installation neuve n'en a pas besoin : les 8 parties la contiennent déjà.
-- =============================================================================

-- ---------- 1 et 2. Lots E2b et E2c ----------
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

-- ---------- 3. Correctifs ----------
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
