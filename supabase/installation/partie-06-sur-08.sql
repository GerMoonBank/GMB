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
