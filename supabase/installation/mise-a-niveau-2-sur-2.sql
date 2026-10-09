-- GerMoonBank · mise à niveau de la base, bloc 2 sur 2
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

create or replace view public.v_bo_files_dossiers with (security_invoker = true) as
select d.id, d.reference, d.type, d.segment, d.etat, d.depose_le, d.sla_echeance, d.analyste_id,
       (d.sla_echeance is not null and d.sla_echeance < now() and d.etat in ('depose', 'en_verification', 'demande_deposee', 'analyse')) as hors_delai,
       p.prenoms, coalesce(nullif(btrim(p.nom_usage), ''), p.nom_naissance) as nom, r.niveau as risque
  from public.dossiers d
  left join public.personnes p on p.id = d.personne_id
  left join public.profils_risque r on r.personne_id = d.personne_id
 where d.etat in ('depose', 'en_verification', 'incomplet', 'analyse_conformite', 'demande_deposee', 'analyse', 'offre_emise', 'delai_legal');

-- ---------- 4. Exploitation ----------
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

-- ---------- 5. Cartes et IBAN (lot E3b) ----------
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

-- ---------- 6. Droits, déclencheurs et données ----------
-- Coordonnées du compte de réception : le site les lit, il ne les modifie jamais
-- directement. Elles ne changent que par gmb_bo_collecte_configurer (trésorerie,
-- journal d'audit) ou par l'exploitant depuis le SQL Editor.
revoke insert, update, delete, truncate on public.parametres_banque from public, anon, authenticated;

-- Horodatage updated_at : ajouté aux tables créées par une mise à jour
do $$
declare r record;
begin
  for r in select c.oid, c.relname from pg_class c
             join pg_namespace n on n.oid = c.relnamespace
             join pg_attribute a on a.attrelid = c.oid and a.attname = 'updated_at' and not a.attisdropped
            where n.nspname = 'public' and c.relkind = 'r' and obj_description(c.oid, 'pg_class') like 'GMB%'
              and not exists (select 1 from pg_trigger t where t.tgrelid = c.oid and t.tgname = 'gmb_maj_horodatage') loop
    execute format('create trigger gmb_maj_horodatage before update on public.%I for each row execute function gmb_prive.maj_horodatage()', r.relname);
  end loop;
end $$;

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

-- Données déjà enregistrées : un texte vide devient « absent »
update public.personnes set nom_usage = null where nom_usage is not null and btrim(nom_usage) = '';
update public.personnes set adresse_ligne2 = null where adresse_ligne2 is not null and btrim(adresse_ligne2) = '';
update public.personnes set nif = null where nif is not null and btrim(nif) = '';

-- L'API de Supabase relit la structure de la base
notify pgrst, 'reload schema';

select public.gmb_version() as version_base,
       (select count(*) from pg_tables where schemaname = 'public') as tables,
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname like 'gmb\_%') as fonctions;
