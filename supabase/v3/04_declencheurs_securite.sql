

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
