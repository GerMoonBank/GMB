-- GerMoonBank · installation de la base, partie 4 sur 8
-- Exécutez les parties dans l'ordre, chacune dans une requête vide du SQL Editor.
-- Contenu : 03_fonctions
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
