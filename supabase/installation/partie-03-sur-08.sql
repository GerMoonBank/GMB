-- GerMoonBank · installation de la base, partie 3 sur 8
-- Exécutez les parties dans l'ordre, chacune dans une requête vide du SQL Editor.
-- Contenu : 03_fonctions
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
