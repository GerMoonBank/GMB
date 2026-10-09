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
