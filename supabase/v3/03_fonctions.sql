

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

-- Consentements horodatés (CGU, confidentialité, biométrie, FICP…)
create or replace function public.gmb_dossier_consentir(p_dossier uuid, p_type text, p_version text, p_accorde boolean)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if not gmb_prive.dossier_du_demandeur(p_dossier) then
    raise exception 'Dossier introuvable.' using errcode = '42501';
  end if;
  insert into public.consentements (auth_user_id, personne_id, type, version, accorde, source)
  values (auth.uid(), (select personne_id from public.dossiers where id = p_dossier), p_type, p_version, p_accorde, 'mon_dossier');
  if p_type = 'ficp' then
    update public.dossier_credit set consentement_ficp = p_accorde where dossier_id = p_dossier;
  end if;
end $$;

-- Dépôt ou remplacement d'une pièce (ONB-07, ONB-08, DOS-04)
create or replace function public.gmb_dossier_piece_deposer(p_dossier uuid, p_type text, p_chemin text,
                                                            p_empreinte text default null, p_date_document date default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_etat text; v_type text; v_reste int;
begin
  if not gmb_prive.dossier_du_demandeur(p_dossier) then
    raise exception 'Dossier introuvable.' using errcode = '42501';
  end if;
  select etat, type into v_etat, v_type from public.dossiers where id = p_dossier for update;
  if v_etat not in ('brouillon', 'incomplet') then
    raise exception 'Ce dossier ne peut plus recevoir de pièce.' using errcode = '55000';
  end if;
  if p_chemin is null or split_part(p_chemin, '/', 1) <> auth.uid()::text then
    raise exception 'Fichier invalide : déposez-le dans votre espace sécurisé.' using errcode = '22023';
  end if;
  update public.dossier_pieces
     set statut = 'deposee', fichier_chemin = p_chemin, empreinte_sha256 = p_empreinte, date_document = p_date_document,
         depose_le = now(), motif_refus_client = null
   where dossier_id = p_dossier and type = p_type and statut in ('attendue', 'refusee', 'facultative', 'deposee');
  if not found then
    insert into public.dossier_pieces (dossier_id, type, statut, fichier_chemin, empreinte_sha256, date_document, depose_le)
    values (p_dossier, p_type, 'deposee', p_chemin, p_empreinte, p_date_document, now());
  end if;
  update public.dossiers set derniere_activite = now() where id = p_dossier;
  select count(*) into v_reste from public.dossier_pieces where dossier_id = p_dossier and statut in ('attendue', 'refusee');
  if v_etat = 'incomplet' and v_reste = 0 then
    update public.dossiers set etat = case when v_type = 'credit' then 'analyse' else 'en_verification' end where id = p_dossier;
  end if;
  return jsonb_build_object('pieces_restantes', v_reste);
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

-- Projet de crédit d'un non-client (ONB-C)
create or replace function public.gmb_dossier_credit_projet(p_dossier uuid, p_montant numeric, p_duree int, p_objet text default 'autre',
                                                            p_revenus numeric default null, p_charges numeric default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare s jsonb;
begin
  if not gmb_prive.dossier_du_demandeur(p_dossier) or (select type from public.dossiers where id = p_dossier) <> 'credit' then
    raise exception 'Dossier de crédit introuvable.' using errcode = '42501';
  end if;
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

-- Dépôt du dossier (ONB-11) : pièces, consentements et premier versement vérifiés
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
  if d.type = 'credit' and not exists (select 1 from public.dossier_credit where dossier_id = p_dossier and consentement_ficp) then
    raise exception 'Votre accord pour la consultation du FICP est nécessaire.' using errcode = '55000';
  end if;
  update public.dossiers
     set etat = case when d.type = 'credit' then 'demande_deposee' else 'depose' end,
         depose_le = now(), sla_echeance = gmb_prive.ajouter_jours_ouvres(now(), 2), etape_tunnel = 11
   where id = p_dossier;
  return jsonb_build_object('reference', d.reference, 'etat', case when d.type = 'credit' then 'demande_deposee' else 'depose' end);
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

-- Acceptation d'une offre de crédit (DOS-06, PAR-13) : délai de rétractation de
-- 14 jours ; versement des fonds possible au plus tôt le 8e jour
create or replace function public.gmb_credit_accepter(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
begin
  if gmb_prive.dossier_du_demandeur(p_id) then
    if (select etat from public.dossiers where id = p_id) <> 'offre_emise' then
      raise exception 'Aucune offre à accepter.' using errcode = '55000';
    end if;
    update public.dossier_credit
       set acceptee_le = now(), retractation_fin = now() + interval '14 days', deblocage_possible_le = (current_date + 7)::timestamptz
     where dossier_id = p_id;
    update public.dossiers set etat = 'delai_legal' where id = p_id;
  elsif exists (select 1 from public.demandes where id = p_id and client_id = gmb_prive.client_courant()) then
    if (select etat from public.demandes where id = p_id) <> 'offre_emise' then
      raise exception 'Aucune offre à accepter.' using errcode = '55000';
    end if;
    update public.demandes
       set etat = 'delai_legal', acceptee_le = now(), retractation_fin = now() + interval '14 days',
           deblocage_possible_le = (current_date + 7)::timestamptz
     where id = p_id;
  else
    raise exception 'Demande introuvable.' using errcode = '42501';
  end if;
  return jsonb_build_object('etat', 'delai_legal', 'retractation_fin', now() + interval '14 days',
                            'deblocage_possible_le', current_date + 7);
end $$;

-- Rétractation (« Me rétracter », DOS-06, PAR-13)
create or replace function public.gmb_credit_retracter(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_etat text; v_fin timestamptz;
begin
  if gmb_prive.dossier_du_demandeur(p_id) then
    select d.etat, c.retractation_fin into v_etat, v_fin from public.dossiers d left join public.dossier_credit c on c.dossier_id = d.id where d.id = p_id;
    if v_etat not in ('offre_emise', 'delai_legal', 'acceptee') or (v_fin is not null and now() > v_fin) then
      raise exception 'Le délai de rétractation est dépassé ou la demande est close.' using errcode = '55000';
    end if;
    update public.dossiers set etat = 'renonciation' where id = p_id;
  elsif exists (select 1 from public.demandes where id = p_id and client_id = gmb_prive.client_courant()) then
    select etat, retractation_fin into v_etat, v_fin from public.demandes where id = p_id;
    if v_etat not in ('demande_deposee', 'analyse', 'offre_emise', 'delai_legal', 'acceptee') or (v_fin is not null and now() > v_fin) then
      raise exception 'Le délai de rétractation est dépassé ou la demande est close.' using errcode = '55000';
    end if;
    update public.demandes set etat = 'renonciation' where id = p_id;
  else
    raise exception 'Demande introuvable.' using errcode = '42501';
  end if;
  return jsonb_build_object('etat', 'renonciation');
end $$;


-- ---------- 11.4 Espace client : paiements ----------------------------------

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

-- Ajout d'un bénéficiaire : plafond temporaire de 1 000 € pendant 72 heures (PAR-05)
create or replace function public.gmb_beneficiaire_ajouter(p_nom text, p_iban text, p_utiliser_nom_verifie boolean default false, p_entreprise uuid default null)
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

-- Trésorerie : exécution d'un virement vers une autre banque (ADM-16)
create or replace function public.gmb_bo_virement_executer(p_virement uuid, p_reference text)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v record; v_client uuid;
begin
  if not gmb_prive.bo_decision('ADM-16') then
    raise exception 'Droits insuffisants.' using errcode = '42501';
  end if;
  select * into v from public.virements where id = p_virement for update;
  if not found or v.statut <> 'a_executer' then
    raise exception 'Ce virement n''est pas en attente d''exécution.' using errcode = '55000';
  end if;
  if coalesce(trim(p_reference), '') = '' then
    raise exception 'Indiquez la référence de l''ordre passé à la banque.' using errcode = '22023';
  end if;
  update public.virements set statut = 'execute', execute_le = now(), reference_execution = trim(p_reference) where id = p_virement;
  select client_id into v_client from public.comptes where id = v.compte_id;
  if v_client is not null then
    perform gmb_prive.notifier(v_client, null, 'Virement envoyé',
      format('Votre virement de %s a été transmis à la banque du bénéficiaire.', gmb_prive.euros(v.montant)), null, 'push');
  end if;
  return jsonb_build_object('statut', 'execute');
end $$;

-- Trésorerie : virement vers une autre banque impossible à exécuter, fonds rendus (ADM-16)
create or replace function public.gmb_bo_virement_rejeter(p_virement uuid, p_motif text)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v record; v_client uuid;
begin
  if not gmb_prive.bo_decision('ADM-16') then
    raise exception 'Droits insuffisants.' using errcode = '42501';
  end if;
  select * into v from public.virements where id = p_virement for update;
  if not found or v.statut <> 'a_executer' then
    raise exception 'Ce virement n''est pas en attente d''exécution.' using errcode = '55000';
  end if;
  if coalesce(trim(p_motif), '') = '' then
    raise exception 'Indiquez le motif du rejet.' using errcode = '22023';
  end if;
  insert into public.operations (compte_id, type, libelle, montant, categorie_code, virement_id, motif)
  values (v.compte_id, 'remboursement', 'Virement non exécuté : fonds restitués', v.montant, 'transferts', v.id, trim(p_motif));
  update public.virements set statut = 'rejete', motif_rejet = trim(p_motif) where id = p_virement;
  select client_id into v_client from public.comptes where id = v.compte_id;
  if v_client is not null then
    perform gmb_prive.notifier(v_client, null, 'Virement non exécuté',
      format('Votre virement de %s n''a pas pu être exécuté : %s. La somme vous est restituée.', gmb_prive.euros(v.montant), trim(p_motif)), null, 'push');
  end if;
  return jsonb_build_object('statut', 'rejete');
end $$;

-- Trésorerie : fonds reçus d'une autre banque pour un client (ADM-16)
-- État d'un service affiché sur la page publique (ADM-01)
create or replace function public.gmb_bo_service_etat(p_service text, p_etat text, p_message text default null)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
begin
  if not gmb_prive.bo_decision('ADM-01') then
    raise exception 'Droits insuffisants.' using errcode = '42501';
  end if;
  update public.statut_services set etat = p_etat, message = nullif(trim(coalesce(p_message, '')), ''), maj_le = now() where service = p_service;
  if not found then
    raise exception 'Service inconnu.' using errcode = '22023';
  end if;
  return jsonb_build_object('service', p_service, 'etat', p_etat);
end $$;

-- Préparation d'un virement (PAR-05, BIZ-04)
create or replace function public.gmb_virement_creer(p_compte uuid, p_beneficiaire uuid, p_montant numeric, p_motif text default null,
                                                     p_type text default 'instantane', p_date date default current_date,
                                                     p_frequence text default null, p_vop_choix text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare c record; b record; v_deja numeric; v_id uuid; v_regle record; v_statut text := 'a_valider';
        v_client uuid := gmb_prive.client_courant();
begin
  if v_client is null or not gmb_prive.compte_accessible(p_compte) then
    raise exception 'Compte introuvable.' using errcode = '42501';
  end if;
  select * into c from public.comptes where id = p_compte;
  if c.type not in ('courant', 'pro', 'business') or c.statut <> 'actif' then
    raise exception 'Les virements partent d''un compte courant actif.' using errcode = '22023';
  end if;
  select * into b from public.beneficiaires
   where id = p_beneficiaire and (client_id = v_client or (entreprise_id is not null and entreprise_id = c.entreprise_id));
  if not found then
    raise exception 'Bénéficiaire introuvable.' using errcode = '42501';
  end if;
  if p_montant is null or p_montant <= 0 then
    raise exception 'Le montant doit être positif.' using errcode = '22023';
  end if;
  if b.vop_resultat in ('partielle', 'aucune', 'impossible') and coalesce(p_vop_choix, '') <> 'continuer' then
    raise exception 'Le nom du bénéficiaire n''a pas été confirmé. Confirmez pour continuer malgré tout.' using errcode = '22023';
  end if;
  if now() < b.plafond_temporaire_jusqu then
    select coalesce(sum(montant), 0) into v_deja from public.virements
     where beneficiaire_id = b.id and statut not in ('rejete', 'annule');
    if v_deja + p_montant > b.plafond_temporaire then
      raise exception 'Nouveau bénéficiaire : plafond de % € pendant 72 heures, par sécurité.', gmb_prive.euros(b.plafond_temporaire)
        using errcode = '22023';
    end if;
  end if;
  if c.entreprise_id is not null then
    select * into v_regle from public.regles_approbation
     where entreprise_id = c.entreprise_id and type_operation = 'virement' and actif and p_montant > seuil
     order by seuil desc limit 1;
    if found then v_statut := 'en_approbation'; end if;
  end if;
  insert into public.virements (compte_id, beneficiaire_id, montant, motif, type, date_execution, frequence, statut,
                                vop_resultat, vop_choix, cree_par)
  values (p_compte, b.id, p_montant, p_motif, coalesce(p_type, 'instantane'), coalesce(p_date, current_date), p_frequence, v_statut,
          b.vop_resultat, p_vop_choix, auth.uid())
  returning id into v_id;
  if v_statut = 'en_approbation' then
    insert into public.demandes_approbation (entreprise_id, regle_id, type, objet_id, libelle, montant, demandeur_id)
    values (c.entreprise_id, v_regle.id, 'virement', v_id, 'Virement · ' || coalesce(b.nom_verifie, b.nom), p_montant, v_client);
  end if;
  return jsonb_build_object('virement', v_id, 'statut', v_statut, 'beneficiaire', coalesce(b.nom_verifie, b.nom), 'montant', p_montant);
end $$;

-- Validation par authentification forte du client
create or replace function public.gmb_virement_valider(p_virement uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v record;
begin
  select * into v from public.virements where id = p_virement;
  if not found or not gmb_prive.compte_accessible(v.compte_id) then
    raise exception 'Virement introuvable.' using errcode = '42501';
  end if;
  if v.statut <> 'a_valider' then
    raise exception 'Ce virement n''est pas à valider.' using errcode = '55000';
  end if;
  update public.virements set statut = 'valide', sca_le = now() where id = p_virement;
  if v.type in ('instantane', 'standard') and v.date_execution <= current_date then
    return gmb_prive.executer_virement(p_virement);
  end if;
  return jsonb_build_object('statut', 'valide', 'date_execution', v.date_execution);
end $$;

create or replace function public.gmb_virement_annuler(p_virement uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v record;
begin
  select * into v from public.virements where id = p_virement;
  if not found or not gmb_prive.compte_accessible(v.compte_id) then
    raise exception 'Virement introuvable.' using errcode = '42501';
  end if;
  if v.statut not in ('a_valider', 'valide', 'en_approbation') or (v.statut = 'valide' and v.date_execution <= current_date) then
    raise exception 'Ce virement ne peut plus être annulé.' using errcode = '55000';
  end if;
  update public.virements set statut = 'annule' where id = p_virement;
  update public.demandes_approbation set statut = 'refusee' where objet_id = p_virement and statut = 'en_attente';
  return jsonb_build_object('statut', 'annule');
end $$;


-- ---------- 11.5 Espace client : cartes, coffres, opérations ----------------

create or replace function public.gmb_carte_regler(p_carte uuid, p_reglage text, p_valeur boolean)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
begin
  if not gmb_prive.carte_accessible(p_carte) then
    raise exception 'Carte introuvable.' using errcode = '42501';
  end if;
  case p_reglage
    when 'gelee' then
      update public.cartes set statut = case when p_valeur then 'gelee' else 'active' end
       where id = p_carte and statut in ('active', 'gelee');
    when 'sans_contact' then update public.cartes set sans_contact = p_valeur where id = p_carte;
    when 'paiement_en_ligne' then update public.cartes set paiement_en_ligne = p_valeur where id = p_carte;
    when 'retraits' then update public.cartes set retraits = p_valeur where id = p_carte;
    when 'etranger' then update public.cartes set etranger = p_valeur where id = p_carte;
    else raise exception 'Réglage inconnu.' using errcode = '22023';
  end case;
  return (select to_jsonb(k) - 'jeton_processeur' from public.cartes k where k.id = p_carte);
end $$;

create or replace function public.gmb_carte_plafonds(p_carte uuid, p_paiement numeric, p_retrait numeric)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
begin
  if not gmb_prive.carte_accessible(p_carte) then
    raise exception 'Carte introuvable.' using errcode = '42501';
  end if;
  if p_paiement not between 50 and 10000 or p_retrait not between 20 and 3000 then
    raise exception 'Plafonds possibles : paiements de 50 € à 10 000 € sur 30 jours, retraits de 20 € à 3 000 € sur 7 jours.' using errcode = '22023';
  end if;
  update public.cartes set plafond_paiement_30j = p_paiement, plafond_retrait_7j = p_retrait where id = p_carte;
  return (select to_jsonb(k) - 'jeton_processeur' from public.cartes k where k.id = p_carte);
end $$;

-- Opposition définitive et commande d'une nouvelle carte (PAR-04)
create or replace function public.gmb_carte_opposition(p_carte uuid, p_motif text)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare k record;
begin
  if not gmb_prive.carte_accessible(p_carte) then
    raise exception 'Carte introuvable.' using errcode = '42501';
  end if;
  select * into k from public.cartes where id = p_carte for update;
  if k.statut = 'opposition' then
    raise exception 'Cette carte est déjà en opposition.' using errcode = '55000';
  end if;
  update public.cartes set statut = 'opposition', motif_opposition = p_motif where id = p_carte;
  perform gmb_prive.notifier(k.titulaire_client_id, null, 'Opposition enregistrée',
    format('Votre carte •••• %s est définitivement bloquée.', k.derniers_chiffres), null, 'push');
  return jsonb_build_object('statut', 'opposition');
end $$;

-- Nouveau coffre (PAR-06) dans la limite de la formule
create or replace function public.gmb_coffre_creer(p_nom text, p_objectif numeric default null, p_date date default null,
                                                   p_arrondi int default 0)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_client uuid := gmb_prive.client_courant(); v_max int; v_parent uuid; v_compte uuid; v_id uuid;
begin
  if v_client is null then
    raise exception 'Connexion requise.' using errcode = '42501';
  end if;
  select f.coffres_max into v_max from public.clients c join public.formules f on f.code = c.formule_code where c.id = v_client;
  if v_max is not null and (select count(*) from public.coffres where client_id = v_client and statut <> 'clos') >= v_max then
    raise exception 'Votre formule permet % coffres. Passez à une formule supérieure pour en créer davantage.', v_max using errcode = '22023';
  end if;
  select id into v_parent from public.comptes
   where client_id = v_client and type in ('courant', 'jeune') and statut = 'actif' order by ouvert_le limit 1;
  insert into public.comptes (client_id, type, libelle, compte_parent_id)
  values (v_client, 'coffre', 'Coffre « ' || p_nom || ' »', v_parent) returning id into v_compte;
  insert into public.coffres (client_id, compte_id, nom, objectif, date_objectif, arrondi_multiplicateur, demarre_le)
  values (v_client, v_compte, p_nom, p_objectif, p_date, coalesce(p_arrondi, 0), current_date) returning id into v_id;
  return jsonb_build_object('coffre', v_id, 'compte', v_compte);
end $$;

-- Alimenter (montant positif) ou retirer (montant négatif) un coffre
create or replace function public.gmb_coffre_mouvement(p_coffre uuid, p_montant numeric)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare k record; v_parent record; v_coffre record;
begin
  select * into k from public.coffres where id = p_coffre and client_id = gmb_prive.client_courant();
  if not found then
    raise exception 'Coffre introuvable.' using errcode = '42501';
  end if;
  select * into v_coffre from public.comptes where id = k.compte_id for update;
  select * into v_parent from public.comptes where id = v_coffre.compte_parent_id for update;
  if p_montant is null or p_montant = 0 then
    raise exception 'Indiquez un montant.' using errcode = '22023';
  end if;
  if p_montant > 0 and v_parent.solde < p_montant then
    raise exception 'Votre solde ne permet pas ce versement. Il vous manque % €.', gmb_prive.euros(p_montant - v_parent.solde) using errcode = '22023';
  end if;
  if p_montant < 0 and v_coffre.solde < -p_montant then
    raise exception 'Le coffre contient seulement % €.', gmb_prive.euros(v_coffre.solde) using errcode = '22023';
  end if;
  insert into public.operations (compte_id, type, libelle, montant, categorie_code) values
    (v_parent.id, 'interne', case when p_montant > 0 then 'Vers « ' || k.nom || ' »' else 'Depuis « ' || k.nom || ' »' end, -p_montant, 'epargne'),
    (v_coffre.id, 'interne', case when p_montant > 0 then 'Versement' else 'Retrait' end, p_montant, 'epargne');
  return jsonb_build_object('solde_coffre', (select solde from public.comptes where id = k.compte_id));
end $$;

-- Catégorie, motif, pointage, justificatif et budget d'une opération (PAR-03)
create or replace function public.gmb_operation_annoter(p_operation uuid, p_categorie text default null, p_motif text default null,
                                                        p_pointee boolean default null, p_justificatif text default null,
                                                        p_budget uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r jsonb;
begin
  update public.operations o
     set categorie_code = coalesce(p_categorie, categorie_code), motif = coalesce(p_motif, motif),
         pointee = coalesce(p_pointee, pointee), justificatif_chemin = coalesce(p_justificatif, justificatif_chemin),
         budget_id = coalesce(p_budget, budget_id)
   where o.id = p_operation and gmb_prive.compte_accessible(o.compte_id)
  returning to_jsonb(o) into r;
  if r is null then
    raise exception 'Opération introuvable.' using errcode = '42501';
  end if;
  return r;
end $$;

-- « Je ne reconnais pas cette opération » (PAR-03) : remboursement au plus tard
-- à la fin du premier jour ouvrable suivant, délai de contestation de 13 mois
create or replace function public.gmb_operation_contester(p_operation uuid, p_motif text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o record; v_id uuid; v_client uuid := gmb_prive.client_courant();
begin
  select * into o from public.operations where id = p_operation;
  if not found or not gmb_prive.compte_accessible(o.compte_id) then
    raise exception 'Opération introuvable.' using errcode = '42501';
  end if;
  if o.montant >= 0 or o.date_operation < now() - interval '13 months' then
    raise exception 'Cette opération ne peut pas être contestée.' using errcode = '22023';
  end if;
  insert into public.contestations (client_id, operation_id, motif, montant, rembourser_avant)
  values (v_client, p_operation, p_motif, -o.montant, gmb_prive.ajouter_jours_ouvres(date_trunc('day', now()), 2) - interval '1 second')
  returning id into v_id;
  insert into public.alertes_fraude (client_id, operation_id, type, score, details)
  values (v_client, p_operation, 'contestation', 60, jsonb_build_object('motif', p_motif));
  return jsonb_build_object('contestation', v_id, 'statut', 'ouverte');
end $$;

-- Conversion de MoonPoints en euros (100 points = 1 €)
create or replace function public.gmb_moonpoints_convertir(p_points int)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_client uuid := gmb_prive.client_courant(); v_solde int; v_compte uuid;
begin
  if v_client is null then
    raise exception 'Connexion requise.' using errcode = '42501';
  end if;
  select coalesce(sum(points), 0) into v_solde from public.moonpoints
   where client_id = v_client and (expire_le is null or expire_le >= current_date);
  if p_points is null or p_points < 100 or p_points > v_solde then
    raise exception 'Conversion possible à partir de 100 MoonPoints, dans la limite de votre solde (% points).', v_solde using errcode = '22023';
  end if;
  select id into v_compte from public.comptes where client_id = v_client and type in ('courant', 'jeune') and statut = 'actif' order by ouvert_le limit 1;
  insert into public.moonpoints (client_id, points, motif) values (v_client, -p_points, 'Conversion en euros');
  insert into public.operations (compte_id, type, libelle, montant, categorie_code)
  values (v_compte, 'moonpoints', 'Conversion de ' || p_points || ' MoonPoints', round(p_points / 100.0, 2), 'epargne');
  return jsonb_build_object('points', p_points, 'euros', round(p_points / 100.0, 2), 'solde_points', v_solde - p_points);
end $$;

-- Demande de prêt personnel d'un client, suivie dans « Mes demandes » (PAR-12, PAR-13)
create or replace function public.gmb_demande_credit(p_montant numeric, p_duree int, p_objet text default 'autre')
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_client uuid := gmb_prive.client_courant(); s jsonb; v_id uuid; v_ref text;
begin
  if v_client is null then
    raise exception 'Connexion requise.' using errcode = '42501';
  end if;
  s := public.gmb_simuler_credit(p_montant, p_duree, p_objet);
  if not (s ->> 'disponible')::boolean then
    raise exception '%', s ->> 'message' using errcode = '22023';
  end if;
  insert into public.demandes (client_id, reference, type, montant, duree_mois, objet, taux_debiteur, taeg, mensualite,
                               cout_total, montant_total_du, donnees)
  values (v_client, gmb_prive.reference('CRE'), 'pret_personnel', p_montant, p_duree, p_objet, (s ->> 'taux_debiteur')::numeric,
          (s ->> 'taeg')::numeric, (s ->> 'mensualite')::numeric, (s ->> 'cout_total')::numeric, (s ->> 'montant_total_du')::numeric, s)
  returning id, reference into v_id, v_ref;
  insert into public.demande_evenements (demande_id, etat_apres, libelle_client) values (v_id, 'demande_deposee', 'Demande de prêt déposée');
  return jsonb_build_object('demande', v_id, 'reference', v_ref) || s;
end $$;

-- Réclamation (PAR-15) : accusé sous 10 jours ouvrables, réponse sous 15 jours
-- ouvrables (paiements) ou 2 mois (autres sujets)
create or replace function public.gmb_reclamation_creer(p_objet text, p_description text, p_categorie text default 'autre')
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_client uuid := gmb_prive.client_courant(); r record;
begin
  if v_client is null then
    raise exception 'Connexion requise.' using errcode = '42501';
  end if;
  insert into public.reclamations (client_id, reference, categorie, objet, description, accuse_avant, reponse_avant)
  values (v_client, gmb_prive.reference('REC'), coalesce(p_categorie, 'autre'), p_objet, p_description,
          gmb_prive.ajouter_jours_ouvres(now(), 10),
          case when p_categorie in ('paiement', 'carte') then gmb_prive.ajouter_jours_ouvres(now(), 15) else now() + interval '2 months' end)
  returning reference, accuse_avant, reponse_avant into r;
  return jsonb_build_object('reference', r.reference, 'accuse_avant', r.accuse_avant, 'reponse_avant', r.reponse_avant);
end $$;

-- Préférences : thème clair, sombre ou système ; langue ; notifications (PAR-16)
create or replace function public.gmb_preferences(p_theme text default null, p_langue text default null, p_preferences jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r jsonb;
begin
  update public.clients c
     set theme = coalesce(p_theme, theme), langue = coalesce(p_langue, langue),
         preferences = preferences || coalesce(p_preferences, '{}'::jsonb)
   where c.id = gmb_prive.client_courant()
  returning jsonb_build_object('theme', c.theme, 'langue', c.langue, 'preferences', c.preferences) into r;
  if r is null then
    raise exception 'Connexion requise.' using errcode = '42501';
  end if;
  return r;
end $$;

create or replace function public.gmb_notification_lue(p_notification uuid default null)
returns int language plpgsql volatile security definer set search_path = '' as $$
declare n int;
begin
  update public.notifications set lu_le = now()
   where lu_le is null and (p_notification is null or id = p_notification)
     and (destinataire_auth = auth.uid() or client_id = gmb_prive.client_courant());
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.gmb_appareil_revoquer(p_appareil uuid)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  update public.appareils set revoque_le = now()
   where id = p_appareil and client_id = gmb_prive.client_courant() and revoque_le is null;
  if not found then
    raise exception 'Appareil introuvable.' using errcode = '42501';
  end if;
end $$;


-- ---------- 11.6 Espace Business et Pro --------------------------------------

-- Décision d'un valideur (BIZ-05) : ordre des rôles, interdiction de valider
-- sa propre demande, exécution du virement après la dernière validation
create or replace function public.gmb_approbation_decider(p_demande uuid, p_decision text, p_commentaire text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare d record; r record; v_client uuid := gmb_prive.client_courant(); v_role text; v_nb int; v_attendu text;
begin
  select * into d from public.demandes_approbation where id = p_demande for update;
  if not found or not gmb_prive.membre_entreprise(d.entreprise_id) then
    raise exception 'Demande introuvable.' using errcode = '42501';
  end if;
  if d.statut <> 'en_attente' then
    raise exception 'Cette demande a déjà été traitée.' using errcode = '55000';
  end if;
  if d.demandeur_id = v_client then
    raise exception 'Vous ne pouvez pas valider votre propre demande.' using errcode = '42501';
  end if;
  if p_decision not in ('validee', 'refusee') then
    raise exception 'Décision inconnue.' using errcode = '22023';
  end if;
  v_role := gmb_prive.role_entreprise(d.entreprise_id);
  select * into r from public.regles_approbation where id = d.regle_id;
  if r.id is not null and not (v_role = any (r.roles_valideurs)) then
    raise exception 'Votre rôle ne permet pas de valider cette demande.' using errcode = '42501';
  end if;
  select count(*) into v_nb from public.approbations where demande_id = p_demande and decision = 'validee';
  v_attendu := case when r.id is not null then r.roles_valideurs[v_nb + 1] end;
  if p_decision = 'validee' and v_attendu is not null and v_attendu <> v_role then
    raise exception 'Validation attendue d''abord du rôle « % ».', replace(v_attendu, '_', ' ') using errcode = '55000';
  end if;
  insert into public.approbations (demande_id, validateur_id, decision, commentaire) values (p_demande, v_client, p_decision, p_commentaire);
  if p_decision = 'refusee' then
    update public.demandes_approbation set statut = 'refusee' where id = p_demande;
    if d.type = 'virement' then
      update public.virements set statut = 'rejete', motif_rejet = 'Refusé lors de l''approbation' where id = d.objet_id;
    elsif d.type = 'note_de_frais' then
      update public.notes_de_frais set statut = 'refusee' where id = d.objet_id;
    end if;
    return jsonb_build_object('statut', 'refusee');
  end if;
  if v_nb + 1 >= coalesce(r.nb_validations, 1) then
    update public.demandes_approbation set statut = 'validee' where id = p_demande;
    if d.type = 'virement' then
      update public.virements set statut = 'valide', sca_le = now() where id = d.objet_id;
      return jsonb_build_object('statut', 'validee') || gmb_prive.executer_virement(d.objet_id);
    elsif d.type = 'note_de_frais' then
      update public.notes_de_frais set statut = 'validee' where id = d.objet_id;
    end if;
    return jsonb_build_object('statut', 'validee');
  end if;
  return jsonb_build_object('statut', 'en_attente', 'validations', v_nb + 1, 'requises', r.nb_validations);
end $$;

-- Note de frais (BIZ-06), soumise au circuit si une règle existe
create or replace function public.gmb_note_de_frais_soumettre(p_entreprise uuid, p_marchand text, p_montant numeric, p_tva numeric,
                                                              p_date date, p_justificatif text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_client uuid := gmb_prive.client_courant(); v_id uuid; v_regle record;
begin
  if not gmb_prive.membre_entreprise(p_entreprise) then
    raise exception 'Entreprise introuvable.' using errcode = '42501';
  end if;
  insert into public.notes_de_frais (entreprise_id, client_id, marchand, montant_ttc, tva, date_depense, justificatif_chemin)
  values (p_entreprise, v_client, p_marchand, p_montant, coalesce(p_tva, 0), p_date, p_justificatif) returning id into v_id;
  select * into v_regle from public.regles_approbation
   where entreprise_id = p_entreprise and type_operation = 'note_de_frais' and actif and p_montant > seuil order by seuil desc limit 1;
  if found then
    insert into public.demandes_approbation (entreprise_id, regle_id, type, objet_id, libelle, montant, demandeur_id)
    values (p_entreprise, v_regle.id, 'note_de_frais', v_id, 'Note de frais · ' || p_marchand, p_montant, v_client);
  else
    update public.notes_de_frais set statut = 'validee' where id = v_id;
  end if;
  return jsonb_build_object('note', v_id);
end $$;


-- ---------- 11.7 Espace Jeunes (parent) ---------------------------------------

create or replace function public.gmb_jeune_regler(p_compte_jeune uuid, p_reglages jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r jsonb;
begin
  update public.comptes_jeunes j set
    plafond_hebdo           = coalesce((p_reglages ->> 'plafond_hebdo')::numeric, plafond_hebdo),
    paiements_en_ligne      = coalesce((p_reglages ->> 'paiements_en_ligne')::boolean, paiements_en_ligne),
    retraits                = coalesce((p_reglages ->> 'retraits')::boolean, retraits),
    etranger                = coalesce((p_reglages ->> 'etranger')::boolean, etranger),
    alerte_paiement         = coalesce((p_reglages ->> 'alerte_paiement')::boolean, alerte_paiement),
    argent_de_poche_montant = coalesce((p_reglages ->> 'argent_de_poche_montant')::numeric, argent_de_poche_montant),
    argent_de_poche_jour    = coalesce((p_reglages ->> 'argent_de_poche_jour')::int, argent_de_poche_jour)
   where j.compte_id = p_compte_jeune and gmb_prive.client_courant() in (j.parent_client_id, j.second_parent_client_id)
  returning to_jsonb(j) into r;
  if r is null then
    raise exception 'Compte Jeunes introuvable.' using errcode = '42501';
  end if;
  return r;
end $$;

create or replace function public.gmb_jeune_envoyer(p_compte_jeune uuid, p_montant numeric)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare j record; v_source record; v_prenom text;
begin
  select * into j from public.comptes_jeunes
   where compte_id = p_compte_jeune and gmb_prive.client_courant() in (parent_client_id, second_parent_client_id);
  if not found then
    raise exception 'Compte Jeunes introuvable.' using errcode = '42501';
  end if;
  select * into v_source from public.comptes
   where client_id = gmb_prive.client_courant() and type = 'courant' and statut = 'actif' order by ouvert_le limit 1 for update;
  if p_montant is null or p_montant <= 0 or v_source.solde < p_montant then
    raise exception 'Montant invalide ou solde insuffisant.' using errcode = '22023';
  end if;
  select p.prenoms into v_prenom from public.clients c join public.personnes p on p.id = c.personne_id where c.id = gmb_prive.client_courant();
  insert into public.operations (compte_id, type, libelle, montant, categorie_code) values
    (v_source.id, 'argent_de_poche', 'Argent de poche', -p_montant, 'transferts'),
    (p_compte_jeune, 'argent_de_poche', 'Argent de poche de ' || coalesce(v_prenom, 'ton parent'), p_montant, 'transferts');
  perform gmb_prive.notifier(j.jeune_client_id, null, 'Argent de poche reçu',
    format('Tu as reçu %s € d''argent de poche.', gmb_prive.euros(p_montant)), null, 'push');
  return jsonb_build_object('statut', 'envoye', 'montant', p_montant);
end $$;


-- ---------- 11.8 Back-office ---------------------------------------------------

-- Ouverture du compte après validation (identifiant, IBAN, Livret, carte,
-- documents, versement crédité, déclaration FICOBA, code d'activation)
create or replace function gmb_prive.ouvrir_compte(p_dossier uuid)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare d record; f record; v record; e record; j record; v_client uuid; v_courant uuid; v_entreprise uuid; v_personne_enfant uuid; v_enfant uuid; v_compte_jeune uuid;
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
  perform gmb_prive.notifier(v_client, d.demandeur_auth, 'Votre compte est ouvert',
    'Votre identifiant bancaire est disponible dans l''Espace Mon Dossier. Activez ensuite votre accès : un code vous sera envoyé par e-mail.',
    '/mon-dossier/', 'email', 'MSG-COMPTE-OUVERT');
  return v_client;
end $$;

-- Prise en charge d'un dossier déposé (ADM-04, ADM-08)
create or replace function public.gmb_bo_dossier_prendre(p_dossier uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare d record;
begin
  select * into d from public.dossiers where id = p_dossier for update;
  if not found or not gmb_prive.bo_decision(case when d.type = 'credit' then 'ADM-08' else 'ADM-04' end) then
    raise exception 'Dossier introuvable ou droits insuffisants.' using errcode = '42501';
  end if;
  if d.etat not in ('depose', 'demande_deposee') then
    raise exception 'Ce dossier est déjà pris en charge.' using errcode = '55000';
  end if;
  update public.dossiers set etat = case when d.type = 'credit' then 'analyse' else 'en_verification' end, analyste_id = auth.uid()
   where id = p_dossier;
  return jsonb_build_object('etat', case when d.type = 'credit' then 'analyse' else 'en_verification' end);
end $$;

-- État d'une pièce (validée ou refusée avec un motif lisible par le client)
create or replace function public.gmb_bo_piece_statuer(p_piece uuid, p_statut text, p_motif_client text default null)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if not gmb_prive.bo_decision('ADM-04') then
    raise exception 'Droits insuffisants.' using errcode = '42501';
  end if;
  if p_statut not in ('validee', 'refusee', 'en_controle') then
    raise exception 'État de pièce inconnu.' using errcode = '22023';
  end if;
  update public.dossier_pieces
     set statut = p_statut, motif_refus_client = case when p_statut = 'refusee' then p_motif_client end, controle_le = now()
   where id = p_piece;
end $$;

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

-- Offre de crédit (ADM-08) : FICP consulté, taux d'effort de 35 % au plus
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
  update public.demandes
     set etat = 'offre_emise', taux_debiteur = v_taux, taeg = gmb_prive.taeg(v_taux), mensualite = v_mens,
         montant_total_du = v_mens * duree_mois, cout_total = v_mens * duree_mois - montant, offre_emise_le = now()
   where id = p_id;
  return jsonb_build_object('etat', 'offre_emise', 'mensualite', v_mens, 'taeg', gmb_prive.taeg(v_taux));
end $$;

-- Tableau d'amortissement
create or replace function gmb_prive.generer_echeancier(p_credit uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c record; v_crd numeric; i int; v_int numeric; v_cap numeric;
begin
  select * into c from public.credits where id = p_credit;
  v_crd := c.montant;
  for i in 1..c.duree_mois loop
    v_int := round(v_crd * c.taux_debiteur / 1200, 2);
    v_cap := case when i = c.duree_mois then v_crd else c.mensualite - v_int end;
    v_crd := v_crd - v_cap;
    insert into public.credit_echeances (credit_id, numero, date_echeance, capital, interets, montant, capital_restant)
    values (p_credit, i, (c.debut + make_interval(months => i))::date, v_cap, v_int, v_cap + v_int, v_crd);
  end loop;
end $$;

-- Versement des fonds (ADM-08), jamais avant le 8e jour suivant l'acceptation
create or replace function public.gmb_bo_credit_debloquer(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare d record; v_compte uuid; v_credit uuid;
begin
  if not gmb_prive.bo_decision('ADM-08') then
    raise exception 'Droits insuffisants.' using errcode = '42501';
  end if;
  if exists (select 1 from public.dossiers where id = p_id and type = 'credit') then
    if (select etat from public.dossiers where id = p_id) <> 'delai_legal'
       or current_date < (select deblocage_possible_le::date from public.dossier_credit where dossier_id = p_id) then
      raise exception 'Versement impossible avant le 8e jour suivant l''acceptation.' using errcode = '55000';
    end if;
    update public.dossiers set etat = 'acceptee' where id = p_id;
    update public.dossier_credit set fonds_debloques_le = now() where dossier_id = p_id;
    update public.dossiers set etat = 'fonds_debloques' where id = p_id;
    return jsonb_build_object('etat', 'fonds_debloques');
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

-- Circuit de publication d'une page (ADM-02) : rédaction, relecture
-- conformité, validation juridique si un bloc réglementé est modifié
create or replace function public.gmb_bo_cms_statut(p_page uuid, p_statut text, p_planifiee_le timestamptz default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare pg record; v_relecteur uuid; v_approbateur uuid;
begin
  select * into pg from public.cms_pages where id = p_page for update;
  if not found then
    raise exception 'Page introuvable.' using errcode = 'P0002';
  end if;
  v_relecteur := pg.relecteur_id;
  v_approbateur := pg.approbateur_id;
  if p_statut in ('brouillon', 'relecture_conformite', 'archivee') then
    if not gmb_prive.bo_ecriture('ADM-02') then
      raise exception 'Droits insuffisants.' using errcode = '42501';
    end if;
  elsif pg.statut = 'relecture_conformite' and p_statut in ('validation_juridique', 'planifiee', 'publiee') then
    if not gmb_prive.a_role('conformite') then
      raise exception 'Relecture réservée à la conformité.' using errcode = '42501';
    end if;
    v_relecteur := auth.uid();
  elsif pg.statut = 'validation_juridique' and p_statut in ('planifiee', 'publiee') then
    if not gmb_prive.a_role('juridique') then
      raise exception 'Validation réservée au service juridique.' using errcode = '42501';
    end if;
    v_approbateur := auth.uid();
  else
    raise exception 'Transition non autorisée : % → %.', pg.statut, p_statut using errcode = '55000';
  end if;
  update public.cms_pages
     set statut = p_statut, relecteur_id = v_relecteur, approbateur_id = v_approbateur,
         planifiee_le = coalesce(p_planifiee_le, planifiee_le),
         en_ligne = case when p_statut = 'archivee' then false else en_ligne end
   where id = p_page;
  return jsonb_build_object('statut', p_statut);
end $$;

-- Paramètre de sécurité (ADM-12) : bornes réglementaires contrôlées par la table
create or replace function public.gmb_bo_parametre_modifier(p_cle text, p_valeur numeric, p_motif text)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if not gmb_prive.bo_ecriture('ADM-12') then
    raise exception 'Droits insuffisants.' using errcode = '42501';
  end if;
  if p_motif is null or length(p_motif) < 5 then
    raise exception 'Indiquez le motif de la modification.' using errcode = '22023';
  end if;
  update public.parametres_securite set valeur = p_valeur, modifie_par = auth.uid(), modifie_le = now() where cle = p_cle;
  if not found then
    raise exception 'Paramètre inconnu.' using errcode = 'P0002';
  end if;
  insert into public.journal_audit (acteur_id, acteur_type, action, objet_type, objet_id, apres, motif)
  values (auth.uid(), 'backoffice', 'PARAMETRE', 'parametres_securite', p_cle, jsonb_build_object('valeur', p_valeur), p_motif);
end $$;

-- Remboursement d'une contestation (ADM-06)
create or replace function public.gmb_bo_contestation_rembourser(p_contestation uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare k record; v_compte uuid;
begin
  if not gmb_prive.bo_ecriture('ADM-06') then
    raise exception 'Droits insuffisants.' using errcode = '42501';
  end if;
  select * into k from public.contestations where id = p_contestation and statut = 'ouverte' for update;
  if not found then
    raise exception 'Contestation introuvable ou déjà traitée.' using errcode = 'P0002';
  end if;
  select compte_id into v_compte from public.operations where id = k.operation_id;
  insert into public.operations (compte_id, type, libelle, montant, categorie_code, reference)
  values (v_compte, 'remboursement', 'Remboursement d''une opération contestée', k.montant, 'transferts', k.operation_id::text);
  update public.contestations set statut = 'remboursee', rembourse_le = now() where id = p_contestation;
  return jsonb_build_object('statut', 'remboursee', 'dans_les_delais', now() <= k.rembourser_avant);
end $$;

-- Traitement d'une alerte LCB-FT (ADM-05) ou de fraude (ADM-06)
create or replace function public.gmb_bo_alerte_traiter(p_type text, p_alerte uuid, p_statut text, p_note text default null)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if p_type = 'lcbft' then
    if not gmb_prive.bo_ecriture('ADM-05') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
    update public.alertes_lcbft set statut = p_statut, traitee_le = now(),
           details = details || jsonb_build_object('note', p_note, 'par', auth.uid()) where id = p_alerte;
  elsif p_type = 'fraude' then
    if not gmb_prive.bo_ecriture('ADM-06') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
    update public.alertes_fraude set statut = p_statut, traitee_le = now(),
           details = details || jsonb_build_object('note', p_note, 'par', auth.uid()) where id = p_alerte;
  else
    raise exception 'Type d''alerte inconnu.' using errcode = '22023';
  end if;
end $$;

-- Nom comparable d'une société ou d'un titulaire : sans accents ni forme juridique
create or replace function gmb_prive.nom_societe(p_nom text) returns text
language sql immutable set search_path = '' as $$
  select btrim(regexp_replace(regexp_replace(gmb_prive.normaliser_nom(p_nom),
    '\m(SASU|SAS|SARL|EURL|SA|SNC|SCI|SELARL|SELAS|EIRL|EI)\M', ' ', 'g'), '\s+', ' ', 'g'))
$$;

-- =============================================================================
-- 16. OUVERTURE DES COMPTES PRO ET BUSINESS (lot 2)
-- =============================================================================

-- Entreprise d'une demande d'ouverture Pro ou Business (connaissance de l'entreprise)
create table if not exists public.dossier_entreprises (
  dossier_id        uuid primary key references public.dossiers(id) on delete cascade,
  raison_sociale    text not null,
  siren             text not null check (siren ~ '^[0-9]{9}$'),
  forme_juridique   text not null check (forme_juridique in ('ei', 'micro', 'eurl', 'sarl', 'sasu', 'sas', 'sa', 'snc', 'sci', 'association', 'autre')),
  date_creation     date,
  code_naf          text check (code_naf is null or code_naf ~ '^[0-9]{2}\.[0-9]{2}[A-Z]$'),
  activite          text,
  adresse_siege     text not null,
  code_postal       text not null check (code_postal ~ '^[0-9]{5}$'),
  ville             text not null,
  effectif          text check (effectif is null or effectif in ('0', '1_9', '10_49', '50_249', '250_plus')),
  chiffre_affaires  text check (chiffre_affaires is null or chiffre_affaires in ('moins_100k', '100k_1m', '1m_10m', 'plus_10m')),
  role_demandeur    text not null default 'dirigeant' check (role_demandeur in ('dirigeant', 'mandataire')),
  beneficiaires     jsonb not null default '[]'::jsonb,
  maj_le            timestamptz not null default now()
);
comment on table public.dossier_entreprises is 'GMB : entreprise d''une demande d''ouverture Pro ou Business (raison sociale, SIREN, siège, bénéficiaires effectifs).';

-- Enregistrement de l'entreprise par le demandeur (ONB-P, ONB-B)
create or replace function public.gmb_dossier_maj_entreprise(p_dossier uuid, p_donnees jsonb)
returns void
language plpgsql volatile security definer set search_path = '' as $$
declare d record; v_siren text := replace(coalesce(p_donnees ->> 'siren', ''), ' ', ''); v_forme text := p_donnees ->> 'forme_juridique';
  b jsonb; v_total numeric := 0;
begin
  if not gmb_prive.dossier_du_demandeur(p_dossier) then
    raise exception 'Dossier introuvable.' using errcode = '42501';
  end if;
  select * into d from public.dossiers where id = p_dossier;
  if d.segment not in ('pro', 'business') then
    raise exception 'Cette demande ne concerne pas une entreprise.' using errcode = '22023';
  end if;
  if d.etat not in ('brouillon', 'incomplet') then
    raise exception 'Ce dossier ne peut plus être modifié.' using errcode = '55000';
  end if;
  if v_siren !~ '^[0-9]{9}$' or not gmb_prive.luhn_valide(v_siren) then
    raise exception 'Ce numéro SIREN n''est pas valide : vérifiez les 9 chiffres.' using errcode = '22023';
  end if;
  if exists (select 1 from public.entreprises where siren = v_siren) then
    raise exception 'Cette entreprise est déjà cliente de GerMoonBank : demandez à son administrateur de vous inviter depuis l''Espace Business.' using errcode = '23505';
  end if;
  if coalesce(trim(p_donnees ->> 'raison_sociale'), '') = '' then
    raise exception 'Indiquez la dénomination de l''entreprise.' using errcode = '22023';
  end if;
  if d.segment = 'pro' and v_forme not in ('ei', 'micro', 'eurl', 'sasu') then
    raise exception 'L''offre Pro est réservée aux entrepreneurs individuels, micro-entrepreneurs, EURL et SASU.' using errcode = '22023';
  end if;
  if d.segment = 'business' and v_forme in ('ei', 'micro') then
    raise exception 'Pour une entreprise individuelle, choisissez l''offre Pro.' using errcode = '22023';
  end if;
  if d.segment = 'business' then
    if jsonb_typeof(p_donnees -> 'beneficiaires') <> 'array' or jsonb_array_length(p_donnees -> 'beneficiaires') = 0 then
      raise exception 'Déclarez au moins un bénéficiaire effectif.' using errcode = '22023';
    end if;
    for b in select * from jsonb_array_elements(p_donnees -> 'beneficiaires') loop
      if coalesce(trim(b ->> 'nom'), '') = '' or coalesce(trim(b ->> 'prenoms'), '') = '' or (b ->> 'date_naissance') is null then
        raise exception 'Indiquez le nom, les prénoms et la date de naissance de chaque bénéficiaire effectif.' using errcode = '22023';
      end if;
      v_total := v_total + coalesce((b ->> 'pourcentage')::numeric, 0);
    end loop;
    if v_total > 100 then
      raise exception 'Le total des parts déclarées dépasse 100 %%.' using errcode = '22023';
    end if;
  end if;
  insert into public.dossier_entreprises (dossier_id, raison_sociale, siren, forme_juridique, date_creation, code_naf, activite,
    adresse_siege, code_postal, ville, effectif, chiffre_affaires, role_demandeur, beneficiaires, maj_le)
  values (p_dossier, trim(p_donnees ->> 'raison_sociale'), v_siren, v_forme, nullif(p_donnees ->> 'date_creation', '')::date,
    nullif(upper(p_donnees ->> 'code_naf'), ''), nullif(trim(coalesce(p_donnees ->> 'activite', '')), ''),
    trim(p_donnees ->> 'adresse_siege'), p_donnees ->> 'code_postal', trim(p_donnees ->> 'ville'),
    nullif(p_donnees ->> 'effectif', ''), nullif(p_donnees ->> 'chiffre_affaires', ''),
    coalesce(nullif(p_donnees ->> 'role_demandeur', ''), 'dirigeant'), coalesce(p_donnees -> 'beneficiaires', '[]'::jsonb), now())
  on conflict (dossier_id) do update set raison_sociale = excluded.raison_sociale, siren = excluded.siren,
    forme_juridique = excluded.forme_juridique, date_creation = excluded.date_creation, code_naf = excluded.code_naf,
    activite = excluded.activite, adresse_siege = excluded.adresse_siege, code_postal = excluded.code_postal,
    ville = excluded.ville, effectif = excluded.effectif, chiffre_affaires = excluded.chiffre_affaires,
    role_demandeur = excluded.role_demandeur, beneficiaires = excluded.beneficiaires, maj_le = now();
  update public.dossiers set derniere_activite = now() where id = p_dossier;
end $$;

-- =============================================================================
-- 17. OUVERTURE DES COMPTES JEUNES (lot C)
-- =============================================================================

-- Enfant d'une demande d'ouverture Jeunes, déposée par un parent
create table if not exists public.dossier_jeunes (
  dossier_id          uuid primary key references public.dossiers(id) on delete cascade,
  civilite            text not null check (civilite in ('madame', 'monsieur')),
  nom                 text not null,
  prenoms             text not null,
  date_naissance      date not null,
  lieu_naissance      text not null,
  pays_naissance      text not null default 'FR',
  nationalite         text not null default 'FR',
  lien                text not null check (lien in ('mere', 'pere', 'tuteur')),
  autorite_parentale  boolean not null check (autorite_parentale),
  maj_le              timestamptz not null default now()
);
comment on table public.dossier_jeunes is 'GMB : enfant d''une demande d''ouverture Jeunes (identité, lien avec le parent demandeur).';

create or replace function public.gmb_dossier_maj_jeune(p_dossier uuid, p_donnees jsonb)
returns void
language plpgsql volatile security definer set search_path = '' as $$
declare d record; v_naissance date; v_age int;
begin
  if not gmb_prive.dossier_du_demandeur(p_dossier) then
    raise exception 'Dossier introuvable.' using errcode = '42501';
  end if;
  select * into d from public.dossiers where id = p_dossier;
  if d.segment <> 'jeunes' then
    raise exception 'Cette demande ne concerne pas un compte Jeunes.' using errcode = '22023';
  end if;
  if d.etat not in ('brouillon', 'incomplet') then
    raise exception 'Ce dossier ne peut plus être modifié.' using errcode = '55000';
  end if;
  if coalesce(trim(p_donnees ->> 'nom'), '') = '' or coalesce(trim(p_donnees ->> 'prenoms'), '') = '' or coalesce(trim(p_donnees ->> 'lieu_naissance'), '') = '' then
    raise exception 'Indiquez le nom, les prénoms et le lieu de naissance de votre enfant.' using errcode = '22023';
  end if;
  begin
    v_naissance := (p_donnees ->> 'date_naissance')::date;
  exception when others then
    raise exception 'Indiquez la date de naissance de votre enfant.' using errcode = '22023';
  end;
  v_age := extract(year from age(current_date, v_naissance))::int;
  if v_naissance is null or v_age < 10 or v_age > 17 then
    raise exception 'Le compte Jeunes est réservé aux enfants de 10 à 17 ans.' using errcode = '22023';
  end if;
  if coalesce(p_donnees ->> 'lien', '') not in ('mere', 'pere', 'tuteur') then
    raise exception 'Indiquez votre lien avec l''enfant.' using errcode = '22023';
  end if;
  if coalesce((p_donnees ->> 'autorite_parentale')::boolean, false) is not true then
    raise exception 'Vous devez exercer l''autorité parentale sur l''enfant pour ouvrir son compte.' using errcode = '22023';
  end if;
  insert into public.dossier_jeunes (dossier_id, civilite, nom, prenoms, date_naissance, lieu_naissance, pays_naissance, nationalite, lien, autorite_parentale, maj_le)
  values (p_dossier, coalesce(nullif(p_donnees ->> 'civilite', ''), 'monsieur'), upper(trim(p_donnees ->> 'nom')), trim(p_donnees ->> 'prenoms'), v_naissance,
          trim(p_donnees ->> 'lieu_naissance'), coalesce(nullif(p_donnees ->> 'pays_naissance', ''), 'FR'), coalesce(nullif(p_donnees ->> 'nationalite', ''), 'FR'),
          p_donnees ->> 'lien', true, now())
  on conflict (dossier_id) do update set civilite = excluded.civilite, nom = excluded.nom, prenoms = excluded.prenoms,
    date_naissance = excluded.date_naissance, lieu_naissance = excluded.lieu_naissance, pays_naissance = excluded.pays_naissance,
    nationalite = excluded.nationalite, lien = excluded.lien, autorite_parentale = true, maj_le = now();
  update public.dossiers set derniere_activite = now() where id = p_dossier;
end $$;

-- =============================================================================
-- 18. CODE SECRET OUBLIÉ OU BLOQUÉ (lot C2)
-- =============================================================================

-- Après vérification par la fonction serveur du code reçu par e-mail : nouveau code
-- secret (mêmes règles de solidité que l'activation) et levée des blocages.
create or replace function public.gmb_code_secret_reinitialiser(p_identifiant text, p_nouveau_code text)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_client uuid; v_lie uuid;
begin
  select id, auth_user_id into v_client, v_lie from public.clients where identifiant = p_identifiant and statut = 'actif';
  if v_client is null or v_lie is null then
    return jsonb_build_object('statut', 'inconnu');
  end if;
  perform gmb_prive.definir_code(v_client, p_nouveau_code);
  update gmb_prive.etat_connexion
     set echecs_consecutifs = 0, echecs_24h = 0, bloque_jusqu = null, bloque_definitif = false, maj_le = now()
   where identifiant = p_identifiant;
  return jsonb_build_object('statut', 'ok', 'client_id', v_client, 'auth_user_id', v_lie);
end $$;

-- =============================================================================
-- 19. BACK-OFFICE : MESSAGES, RÉCLAMATIONS, COLLABORATEURS (lot D)
-- =============================================================================

-- Réponse d'un conseiller dans l'Espace Mon Dossier (dossier d'ouverture ou de crédit)
create or replace function public.gmb_bo_dossier_message(p_dossier uuid, p_contenu text)
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare v_type text; v_id uuid;
begin
  select type into v_type from public.dossiers where id = p_dossier;
  if v_type is null then raise exception 'Dossier introuvable.' using errcode = '22023'; end if;
  if not gmb_prive.bo_decision(case when v_type = 'credit' then 'ADM-08' else 'ADM-04' end) then
    raise exception 'Droits insuffisants.' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_contenu, ''))) < 2 then raise exception 'Écrivez votre message.' using errcode = '22023'; end if;
  insert into public.dossier_messages (dossier_id, auteur, auteur_id, contenu) values (p_dossier, 'conseiller', auth.uid(), trim(p_contenu)) returning id into v_id;
  return v_id;
end $$;

-- Réponse d'un conseiller dans la messagerie de l'Espace client
create or replace function public.gmb_bo_message(p_fil uuid, p_contenu text, p_clore boolean default false)
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not gmb_prive.bo_decision('ADM-09') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
  if not exists (select 1 from public.fils_messagerie where id = p_fil) then raise exception 'Conversation introuvable.' using errcode = '22023'; end if;
  if length(trim(coalesce(p_contenu, ''))) < 2 then raise exception 'Écrivez votre message.' using errcode = '22023'; end if;
  insert into public.messages (fil_id, auteur, auteur_id, contenu) values (p_fil, 'conseiller', auth.uid(), trim(p_contenu)) returning id into v_id;
  update public.fils_messagerie set statut = case when p_clore then 'clos' else 'en_attente_client' end, updated_at = now() where id = p_fil;
  return v_id;
end $$;

-- Réclamation : accusé de réception, puis réponse (et clôture)
create or replace function public.gmb_bo_reclamation_accuser(p_reclamation uuid)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if not gmb_prive.bo_decision('ADM-09') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
  update public.reclamations set statut = 'en_cours', accuse_le = coalesce(accuse_le, now()) where id = p_reclamation and statut = 'recue';
  if not found and not exists (select 1 from public.reclamations where id = p_reclamation) then raise exception 'Réclamation introuvable.' using errcode = '22023'; end if;
end $$;

create or replace function public.gmb_bo_reclamation_repondre(p_reclamation uuid, p_reponse text, p_clore boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r record;
begin
  if not gmb_prive.bo_decision('ADM-09') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
  if length(trim(coalesce(p_reponse, ''))) < 20 then raise exception 'Rédigez une réponse complète (20 caractères au moins).' using errcode = '22023'; end if;
  select * into r from public.reclamations where id = p_reclamation;
  if not found then raise exception 'Réclamation introuvable.' using errcode = '22023'; end if;
  if r.statut = 'close' then raise exception 'Cette réclamation est close.' using errcode = '55000'; end if;
  update public.reclamations
     set reponse = trim(p_reponse), repondue_le = now(), accuse_le = coalesce(accuse_le, now()),
         statut = case when p_clore then 'close' else 'repondue' end
   where id = p_reclamation;
  return jsonb_build_object('statut', case when p_clore then 'close' else 'repondue' end, 'dans_les_delais', now() <= coalesce(r.reponse_avant, now()));
end $$;

-- Collaborateurs : rôles et activation (habilitations, ADM-13)
create or replace function public.gmb_bo_collaborateur_role(p_collaborateur uuid, p_role text, p_attribuer boolean)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if not gmb_prive.bo_decision('ADM-13') then raise exception 'Droits insuffisants.' using errcode = '42501'; end if;
  if p_collaborateur = auth.uid() then raise exception 'Vous ne pouvez pas modifier vos propres rôles.' using errcode = '42501'; end if;
  if not exists (select 1 from public.collaborateurs where id = p_collaborateur) then raise exception 'Collaborateur introuvable.' using errcode = '22023'; end if;
  if not exists (select 1 from public.roles_bo where code = p_role) then raise exception 'Rôle inconnu.' using errcode = '22023'; end if;
  if p_attribuer then
    insert into public.collaborateur_roles (collaborateur_id, role_code) values (p_collaborateur, p_role) on conflict do nothing;
  else
    delete from public.collaborateur_roles where collaborateur_id = p_collaborateur and role_code = p_role;
  end if;
end $$;

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