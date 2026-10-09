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
