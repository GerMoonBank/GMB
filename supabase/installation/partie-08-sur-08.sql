-- GerMoonBank · installation de la base, partie 8 sur 8
-- Exécutez les parties dans l'ordre, chacune dans une requête vide du SQL Editor.
-- Contenu : 04_declencheurs_securite, 05_reference, 06_administration, gmb_mode_developpement.sql
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


-- =============================================================================
-- 15. DONNÉES DE RÉFÉRENCE (cahier des charges v2.1, chapitres 3, 6, 12 et 18)
-- =============================================================================
insert into public.formules (code, segment, nom, accroche, prix_mensuel, prix_ht, carte, retraits_hors_zone_mois, change_sans_frais_mois,
                             taux_livret, moonpoints_taux, coffres_max, cartes_physiques, cartes_virtuelles, utilisateurs_max,
                             operations_incluses, assurances, services, badge, ordre) values
  ('luna',  'particulier', 'Luna',  'L''essentiel du quotidien, sans frais cachés.', 0,     false, 'Débit', 200,  1000, 2.00, 0,    3,    1, 1,  null, null, '{}', '{support_application}', null, 1),
  ('halo',  'particulier', 'Halo',  'Pour voyager léger et épargner mieux.',          4.90,  false, 'Débit, design au choix', 400, 3000, 2.50, 0.25, 10, 1, 3, null, null, '{}', '{support_prioritaire}', null, 2),
  ('orbit', 'particulier', 'Orbit', 'Assurances voyage et achats incluses.',          9.90,  false, 'Débit premium', 800, 8000, 3.25, 0.50, null, 1, 5, null, null, '{voyage,achats}', '{support_prioritaire}', 'Le plus choisi', 3),
  ('eclipse','particulier','Éclipse','Carte métal et protection étendue.',            16.90, false, 'Métal', 1500, null, 4.00, 0.75, null, 1, 10, null, null,
   '{voyage,achats,annulation,location_vehicule,telephone}', '{ligne_dediee}', null, 4),
  ('zenith','particulier', 'Zénith','Le meilleur taux et un conseiller dédié.',        49.00, false, 'Métal', 3000, null, 5.25, 1.00, null, 1, 20, null, null,
   '{voyage,achats,annulation,location_vehicule,telephone,famille}', '{conseiller_dedie,salons_aeroport}', null, 5),
  ('pro_solo',       'pro',      'Pro Solo',        'Facturer, encaisser et provisionner au même endroit.', 9,   true, 'Débit Pro', null, null, null, 0, null, 1,   5,    1,    100,   '{}', '{facturation_electronique,provisions,export_comptable}', null, 10),
  ('pro_plus',       'pro',      'Pro Plus',        'Liens de paiement et relances automatiques.',          19,  true, 'Débit Pro', null, null, null, 0, null, 2,   20,   2,    300,   '{}', '{liens_paiement,relances,comptable_invite}', null, 11),
  ('business_start', 'business', 'Business Start',  'Rôles, approbations et notes de frais.',               29,  true, 'Business',  null, null, null, 0, null, 5,   20,   5,    500,   '{}', '{roles,approbations,notes_de_frais}', null, 20),
  ('business_growth','business', 'Business Growth', 'Approbations à plusieurs niveaux et API en lecture.',  79,  true, 'Business',  null, null, null, 0, null, 20,  100,  20,   2000,  '{}', '{approbations_multiniveaux,lecture_justificatifs,api_lecture}', null, 21),
  ('business_scale', 'business', 'Business Scale',  'API complète, webhooks et support dédié.',             199, true, 'Business',  null, null, null, 0, null, 100, 1000, null, 10000, '{}', '{api_complete,webhooks,virements_groupes,support_dedie}', null, 22);

insert into public.frais (code, libelle, pourcentage, montant, minimum, conditions) values
  ('retrait_hors_zone', 'Retrait hors zone euro au-delà de la franchise', 2.000, null, 1.00, 'Franchise mensuelle selon la formule'),
  ('change',            'Paiement en devise au-delà de la franchise',     0.500, null, null, 'Écart avec le taux de référence de la BCE affiché avant paiement'),
  ('majoration_week_end','Majoration du change le week-end',              1.000, null, null, 'Marchés fermés, du vendredi soir au dimanche soir'),
  ('operation_sup_pro', 'Opération SEPA au-delà du forfait Pro ou Business', null, 0.20, null, 'Montant hors taxes');

-- Valeur indicative : à mettre à jour chaque trimestre avec le taux publié au Journal officiel
insert into public.taux_usure (categorie, taux, valable_du, valable_au, source) values
  ('conso_plus_6000', 8.500, '2026-01-01', '2027-12-31', 'Taux d''usure : à vérifier et mettre à jour chaque trimestre (publication de la Banque de France)');

insert into public.grilles_credit (objet, montant_min, montant_max, duree_min, duree_max, taux_debiteur, valide_conformite) values
  ('tous', 1000, 50000, 6,  24, 4.900, true),
  ('tous', 1000, 50000, 25, 48, 5.750, true),   -- exemple de référence : 10 000 € sur 48 mois → 233,71 €
  ('tous', 1000, 50000, 49, 84, 6.250, true);

insert into public.categories (code, libelle, icone, couleur, ordre) values
  ('alimentation', 'Courses', 'shopping-cart', 'teal', 1), ('restaurants', 'Restaurants', 'utensils', 'rose', 2),
  ('transports', 'Transports', 'train-front', 'violet', 3), ('logement', 'Logement', 'house', 'violet', 4),
  ('loisirs', 'Loisirs', 'ticket', 'rose', 5), ('sante', 'Santé', 'heart-pulse', 'teal', 6),
  ('shopping', 'Shopping', 'shopping-bag', 'rose', 7), ('voyages', 'Voyages', 'plane', 'teal', 8),
  ('abonnements', 'Abonnements', 'repeat', 'violet', 9), ('salaire', 'Revenus', 'banknote', 'teal', 10),
  ('epargne', 'Épargne', 'piggy-bank', 'teal', 11), ('impots', 'Impôts', 'landmark', 'violet', 12),
  ('transferts', 'Virements', 'arrow-left-right', 'violet', 13), ('frais', 'Frais bancaires', 'receipt', 'violet', 14),
  ('autres', 'Autres', 'circle-dot', 'violet', 15);

insert into public.cms_textes_legaux (code, titre, contenu, entite) values
  ('LEG-FGDR-02', 'Garantie des dépôts',
   'Vous pouvez y aller en toute confiance : vos dépôts sont couverts par la garantie du FGDR jusqu''à 100 000 € par déposant et par établissement, auprès de [établissement partenaire].', '[établissement partenaire]'),
  ('LEG-CREDIT-01', 'Mention obligatoire du crédit',
   'Un crédit vous engage et doit être remboursé. Vérifiez vos capacités de remboursement avant de vous engager.', null),
  ('LEG-CREDIT-EX-01', 'Exemple représentatif du prêt personnel',
   'Exemple représentatif : pour un prêt personnel de 10 000 € sur 48 mois au taux débiteur fixe de 5,75 %, soit un TAEG fixe de 5,90 %, vous remboursez 48 mensualités de 233,71 € (hors assurance facultative). Montant total dû : 11 218,08 €. Coût total du crédit : 1 218,08 €. Offre soumise à conditions, sous réserve d''acceptation de votre dossier par le prêteur. Délai de rétractation de 14 jours.', null),
  ('LEG-CRYPTO-01', 'Avertissement crypto-actifs',
   'Les crypto-actifs sont volatils : vous pouvez perdre tout ou partie de votre investissement. Ils ne sont pas couverts par la garantie des dépôts. Service réservé aux majeurs, fourni par un prestataire agréé MiCA.', null),
  ('LEG-LIVRET-01', 'Taux du Livret GMB', 'Taux annuels bruts, révisables, avant prélèvements fiscaux et sociaux.', null),
  ('LEG-MARQUE-01', 'Identité de la marque',
   'GerMoonBank est une marque de The Hub of Inspiration of Soccer (RCCM RB/ABC/24 A 111814). Services bancaires fournis par [établissement partenaire], agréé par l''ACPR.', 'The Hub of Inspiration of Soccer'),
  ('LEG-PROSPECTS-01', 'Données des demandeurs',
   'Les données de votre demande sont conservées 12 mois si elle n''aboutit pas, puis supprimées ou anonymisées à des fins statistiques, sauf obligation légale. Les échanges avec nos conseillers peuvent être enregistrés.', null),
  ('LEG-COOKIES-01', 'Cookies',
   'Nous utilisons des cookies pour faire fonctionner le site et, avec votre accord, pour mesurer son audience. Vous pouvez accepter, refuser ou personnaliser vos choix à tout moment.', null);

insert into public.cms_bandeaux (niveau, message, lien_libelle, lien_url, conditions_url) values
  ('promotion', 'Livret GMB : jusqu''à 5,25 % brut par an avec la formule Zénith.', 'Voir les conditions',
   '/particuliers/epargne/', '/particuliers/epargne/#conditions');

insert into public.cms_pages (ecran, slug, titre, titre_seo, description_seo, blocs, statut, en_ligne, publiee_le) values
  ('VIT-01', '', 'Accueil', 'GerMoonBank — La banque qui veille sur votre argent',
   'Compte, carte, épargne rémunérée chaque jour, bourse et crédit dans une seule application sécurisée.',
   '[{"type":"heros","titre":"La banque qui veille sur votre argent, jour et nuit.","sous_titre":"Compte, carte, épargne rémunérée chaque jour, bourse et crédit dans une seule application.","boutons":[{"libelle":"Ouvrir un compte","lien":"/souscrire/"},{"libelle":"Découvrir les formules","lien":"/particuliers/tarifs/"}]},
     {"type":"confiance","elements":["Virements instantanés gratuits","Carte Luna à 0 €","Épargne rémunérée","Service client 7 j/7"]},
     {"type":"segments"},{"type":"epargne","formule":"zenith","montant":10000},{"type":"securite"},{"type":"formules"},
     {"type":"faq","rubrique":"accueil"},{"type":"mentions","codes":["LEG-FGDR-02","LEG-MARQUE-01"],"reglemente":true}]',
   'publiee', true, now()),
  ('VIT-11', 'particuliers/epargne', 'Épargne et Livret GMB', 'Livret GMB : intérêts versés chaque jour',
   'Faites grandir votre épargne chaque jour : intérêts calculés et versés quotidiennement, argent disponible à tout moment.',
   '[{"type":"heros","titre":"Faites grandir votre épargne, chaque jour.","sous_titre":"Intérêts calculés et versés quotidiennement, argent disponible à tout moment."},
     {"type":"taux_formules","source":"catalogue"},{"type":"simulateur_epargne","montant":10000,"formule":"zenith"},
     {"type":"coffres"},{"type":"faq","rubrique":"epargne"},{"type":"mentions","codes":["LEG-LIVRET-01","LEG-FGDR-02"],"reglemente":true}]',
   'publiee', true, now()),
  ('VIT-15', 'particuliers/credits', 'Crédits et simulateur', 'Prêt personnel : simulez votre mensualité',
   'De 1 000 € à 50 000 € sur 6 à 84 mois, à taux fixe et sans frais de dossier. Réponse de principe immédiate.',
   '[{"type":"heros","titre":"Un projet ? Simulez votre mensualité en toute transparence."},
     {"type":"simulateur_credit","montant":10000,"duree":48},{"type":"mentions","codes":["LEG-CREDIT-01","LEG-CREDIT-EX-01"],"reglemente":true}]',
   'publiee', true, now());

insert into public.cms_faq (rubrique, question, reponse, ordre) values
  ('accueil', 'Quelle différence entre Mon Dossier et l''Espace client ?',
   'L''Espace Mon Dossier sert à suivre une demande d''ouverture de compte ou de crédit, avec votre e-mail et un mot de passe. L''Espace client donne accès à vos comptes, avec votre identifiant bancaire, votre code secret et votre téléphone de confiance.', 1),
  ('accueil', 'Combien de temps pour ouvrir un compte ?',
   'Environ 8 minutes de saisie. Nous vérifions votre dossier sous 48 heures ouvrées et vous suivez chaque étape dans l''Espace Mon Dossier.', 2),
  ('accueil', 'Mon argent est-il protégé ?',
   'Vos dépôts sont couverts par la garantie du FGDR jusqu''à 100 000 € par déposant et par établissement. Les crypto-actifs ne sont pas couverts.', 3),
  ('epargne', 'Quand mes intérêts sont-ils versés ?', 'Chaque jour : ils sont calculés sur votre solde de fin de journée et versés sur votre Livret GMB.', 1),
  ('epargne', 'Puis-je retirer mon argent à tout moment ?', 'Oui, votre épargne est disponible immédiatement vers votre compte courant GerMoonBank.', 2),
  ('securite', 'GerMoonBank peut-il me demander mon code secret ?',
   'Jamais : ni par téléphone, ni par e-mail, ni par SMS. En cas de doute, raccrochez et contactez-nous depuis l''application.', 1);

insert into public.statut_services (service, libelle) values
  ('connexion', 'Connexion à l''Espace client'), ('cartes', 'Paiements par carte'), ('virements', 'Virements'),
  ('application', 'Application mobile'), ('mon_dossier', 'Espace Mon Dossier'), ('api', 'API Business');

insert into public.roles_bo (code, libelle) values
  ('conformite', 'Conformité'), ('analyste_kyc', 'Analyste KYC'), ('conseiller', 'Conseiller'), ('fraude', 'Fraude'),
  ('credit', 'Crédit'), ('marketing', 'Contenu et marketing'), ('juridique', 'Juridique'), ('finance', 'Finance'),
  ('securite', 'Sécurité'), ('audit', 'Audit interne'), ('direction', 'Direction');

insert into public.modules_bo (code, libelle, adresse) values
  ('ADM-01', 'Tableau de bord opérationnel', '/bo/'),            ('ADM-02', 'CMS et bibliothèque juridique', '/bo/cms'),
  ('ADM-03', 'Catalogue, tarifs et taux', '/bo/catalogue'),      ('ADM-04', 'Dossiers et KYC', '/bo/dossiers'),
  ('ADM-05', 'LCB-FT et filtrage', '/bo/lcb-ft'),                ('ADM-06', 'Fraude, litiges et contestations', '/bo/fraude'),
  ('ADM-07', 'Clients 360°', '/bo/clients'),                     ('ADM-08', 'Crédits', '/bo/credits'),
  ('ADM-09', 'Support, messagerie et réclamations', '/bo/support'), ('ADM-10', 'Notifications et modèles', '/bo/notifications'),
  ('ADM-11', 'Pro, Business et API', '/bo/entreprises'),         ('ADM-12', 'Sécurité et authentification', '/bo/securite'),
  ('ADM-13', 'Habilitations', '/bo/habilitations'),              ('ADM-14', 'Journal d''audit', '/bo/audit'),
  ('ADM-15', 'Reporting et pilotage', '/bo/reporting'),          ('ADM-16', 'Trésorerie et comptabilité', '/bo/tresorerie');

-- Matrice des habilitations (chapitre 18) : L lecture, E écriture, V validation, A administration, - aucun accès
do $$
declare
  v_roles text[] := array['conformite', 'analyste_kyc', 'conseiller', 'fraude', 'credit', 'marketing', 'juridique', 'finance', 'securite', 'audit', 'direction'];
  v_ligne text; v_cases text[]; i int;
begin
  foreach v_ligne in array array[
    'ADM-01 L L L L L L L L L L L', 'ADM-02 V - - - - E V - - L L', 'ADM-03 V - - - E E L E - L L', 'ADM-04 V E L L - - - - - L L',
    'ADM-05 E L - L - - - - - L L', 'ADM-06 L - L E - - - L L L L', 'ADM-07 L L E L L - - L - L L', 'ADM-08 L - L - E - - L - L L',
    'ADM-09 L - E L L - L - - L L', 'ADM-10 V - - - - E V - - L L', 'ADM-11 L E E L - - - L L L L', 'ADM-12 L - - L - - - - A L L',
    'ADM-13 L - - - - - - - A L V', 'ADM-14 L - - L - - L - L L L', 'ADM-15 L L L L L L L L L L L', 'ADM-16 L - - - - - - E - L L'] loop
    v_cases := regexp_split_to_array(v_ligne, '\s+');
    for i in 1..array_length(v_roles, 1) loop
      if v_cases[i + 1] <> '-' then
        insert into public.habilitations (module_code, role_code, droit) values (v_cases[1], v_roles[i], v_cases[i + 1]);
      end if;
    end loop;
  end loop;
end $$;

insert into public.parametres_securite (cle, valeur, valeur_min, valeur_max, unite, description, modifiable) values
  ('grille_ttl_secondes',            120, 60, 180,  'secondes',   'Validité d''une grille du clavier virtuel', true),
  ('echecs_avant_blocage',           3,   1,  5,    'essais',     'Échecs consécutifs avant blocage temporaire (5 au plus, DSP2)', true),
  ('blocage_minutes',                30,  15, 1440, 'minutes',    'Durée du blocage temporaire', true),
  ('echecs_24h_blocage_definitif',   6,   3,  10,   'essais',     'Échecs sur 24 heures avant blocage complet', true),
  ('inactivite_minutes',             5,   1,  5,    'minutes',    'Déconnexion après inactivité (5 minutes au plus, DSP2)', false),
  ('alerte_inactivite_minutes',      4,   1,  4,    'minutes',    'Alerte avant la déconnexion', true),
  ('session_max_minutes',            60,  15, 120,  'minutes',    'Durée maximale d''une session', true),
  ('masquage_carte_secondes',        30,  10, 60,   'secondes',   'Masquage automatique des données de carte', true),
  ('nouveau_beneficiaire_plafond',   1000, 0, 5000, 'euros',      'Plafond d''un nouveau bénéficiaire', true),
  ('nouveau_beneficiaire_heures',    72,  24, 168,  'heures',     'Durée du plafond d''un nouveau bénéficiaire', true),
  ('mon_dossier_inactivite_minutes', 15,  5,  30,   'minutes',    'Déconnexion de l''Espace Mon Dossier', true),
  ('mon_dossier_tentatives',         5,   3,  10,   'essais',     'Tentatives de connexion à Mon Dossier par 15 minutes', true),
  ('mot_de_passe_longueur_min',      12,  12, 64,   'caractères', 'Longueur minimale du mot de passe Mon Dossier', true),
  ('code_activation_heures',         72,  24, 72,   'heures',     'Validité du code d''activation', true),
  ('approbation_expiration_jours',   7,   1,  30,   'jours',      'Expiration d''une demande d''approbation', true),
  ('complement_delai_jours',         30,  7,  60,   'jours',      'Délai accordé pour fournir un complément', true),
  ('brouillon_abandon_jours',        30,  7,  90,   'jours',      'Clôture d''un brouillon inactif', true),
  ('incomplet_abandon_jours',        60,  30, 120,  'jours',      'Clôture d''un dossier incomplet sans réponse', true),
  ('prospects_conservation_mois',    12,  12, 60,   'mois',       'Conservation des données d''un demandeur non client', true);

insert into public.modeles_notification (code, canal, sujet, contenu, variables) values
  ('MSG-ACCES-01', 'email', 'Votre code de vérification', 'Votre code de vérification GerMoonBank : {{code}}. Il est valable 10 minutes.', '{code}'),
  ('MSG-RELANCE-01', 'email', 'Votre demande vous attend',
   'Bonjour {{prenom}}, votre demande {{reference}} est enregistrée. Reprenez-la quand vous le souhaitez depuis l''Espace Mon Dossier.', '{prenom,reference}'),
  ('MSG-DEPOT-01', 'email', 'Votre dossier est déposé',
   'Bonjour {{prenom}}, nous avons bien reçu votre dossier {{reference}}. Nous vérifions vos pièces sous 48 heures ouvrées.', '{prenom,reference}'),
  ('MSG-KYC-01', 'message_dossier', 'Pièce illisible',
   'Bonjour, la pièce transmise n''est pas lisible. Merci d''en déposer une nouvelle photo, nette et entière, dans votre Espace Mon Dossier.', '{}'),
  ('MSG-KYC-04', 'message_dossier', 'Justificatif de domicile',
   'Bonjour, merci pour votre demande. Il nous manque un justificatif de domicile récent pour poursuivre : le document transmis date de plus de 3 mois. Déposez une facture d''énergie ou de téléphone, un avis d''imposition ou une quittance de loyer émise par un professionnel.', '{}'),
  ('MSG-ACCORD-01', 'email', 'Votre compte est ouvert',
   'Bonne nouvelle {{prenom}} : votre compte est ouvert. Retrouvez votre identifiant bancaire dans l''Espace Mon Dossier, puis activez votre accès : un code vous sera envoyé par e-mail.', '{prenom}'),
  ('MSG-REFUS-01', 'message_dossier', 'Votre demande',
   'Après étude de votre dossier, nous ne pouvons pas donner une suite favorable à votre demande. Votre premier versement vous est remboursé sous 5 jours ouvrés.', '{}'),
  ('MSG-BENEF-01', 'push', 'Nouveau bénéficiaire', '{{nom}} a été ajouté à vos bénéficiaires. Si ce n''était pas vous, contactez-nous immédiatement.', '{nom}'),
  ('MSG-CONNEXION-BLOQUEE', 'email', 'Accès bloqué par sécurité',
   'Plusieurs codes erronés ont été saisis sur votre accès. Si ce n''était pas vous, contactez-nous depuis l''application.', '{}'),
  ('MSG-RECLAMATION-AR', 'email', 'Nous avons reçu votre réclamation',
   'Votre réclamation {{reference}} est enregistrée. Nous vous répondrons au plus tard le {{date_limite}}.', '{reference,date_limite}');

insert into public.defis (code, titre, description, objectif, recompense) values
  ('mettre_5_euros', 'Mets 5 € de côté avant dimanche', 'Verse au moins 5 € dans un de tes coffres cette semaine.', 5, 20),
  ('trois_jours_sans_achat', 'Trois jours sans achat plaisir', 'Évite les achats non prévus pendant trois jours.', null, 30),
  ('objectif_atteint', 'Atteins ton premier objectif', 'Remplis complètement un de tes coffres.', null, 100);


-- Coordonnées de collecte : à renseigner avec gmb_prive.configurer_collecte(...)
insert into public.parametres_banque (cle, valeur, libelle) values
  ('collecte_titulaire', '', 'Titulaire du compte de collecte'),
  ('collecte_iban', '', 'IBAN du compte de collecte'),
  ('collecte_bic', '', 'BIC du compte de collecte'),
  ('collecte_banque', '', 'Banque du compte de collecte')
on conflict (cle) do nothing;

-- =============================================================================
-- 15. ADMINISTRATION : premier administrateur et compte de collecte
-- =============================================================================

-- Premier administrateur du back-office. L'utilisateur doit exister dans
-- Authentication → Users (Add user, Auto Confirm User). Il reçoit tous les rôles.
--   select gmb_prive.creer_administrateur('vous@exemple.fr', 'Votre nom');
create or replace function gmb_prive.creer_administrateur(p_email text, p_nom text default null)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_id uuid; v_email text := lower(trim(coalesce(p_email, '')));
begin
  select id into v_id from auth.users where lower(email) = v_email;
  if v_id is null then
    raise exception 'Créez d''abord l''utilisateur % dans Authentication → Users (Add user, Auto Confirm User).', v_email;
  end if;
  update auth.users set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"espace": "backoffice"}'::jsonb where id = v_id;
  insert into public.collaborateurs (id, nom, email)
  values (v_id, coalesce(nullif(trim(coalesce(p_nom, '')), ''), split_part(v_email, '@', 1)), v_email)
  on conflict (id) do update set actif = true, nom = excluded.nom, email = excluded.email;
  insert into public.collaborateur_roles (collaborateur_id, role_code)
  select v_id, code from public.roles_bo on conflict do nothing;
  return jsonb_build_object('administrateur', v_email,
    'roles', (select count(*) from public.collaborateur_roles where collaborateur_id = v_id));
end $$;

-- Compte bancaire réel de GerMoonBank qui reçoit les premiers versements et les
-- virements destinés aux clients :
--   select gmb_prive.configurer_collecte('Titulaire', 'FR76 ...', 'BIC', 'Nom de la banque');
create or replace function gmb_prive.configurer_collecte(p_titulaire text, p_iban text, p_bic text, p_banque text)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_iban text := upper(replace(coalesce(p_iban, ''), ' ', ''));
begin
  if not gmb_prive.iban_valide(v_iban) then
    raise exception 'IBAN invalide : vérifiez-le.' using errcode = '22023';
  end if;
  if coalesce(trim(p_titulaire), '') = '' then
    raise exception 'Indiquez le titulaire du compte.' using errcode = '22023';
  end if;
  insert into public.parametres_banque (cle, valeur, libelle) values
    ('collecte_titulaire', trim(p_titulaire), 'Titulaire du compte de collecte'),
    ('collecte_iban', v_iban, 'IBAN du compte de collecte'),
    ('collecte_bic', upper(trim(coalesce(p_bic, ''))), 'BIC du compte de collecte'),
    ('collecte_banque', trim(coalesce(p_banque, '')), 'Banque du compte de collecte')
  on conflict (cle) do update set valeur = excluded.valeur, modifie_le = now();
  return jsonb_build_object('titulaire', trim(p_titulaire), 'iban', v_iban);
end $$;

revoke execute on function gmb_prive.creer_administrateur(text, text) from public, anon, authenticated, service_role;
revoke execute on function gmb_prive.configurer_collecte(text, text, text, text) from public, anon, authenticated, service_role;
-- =============================================================================
-- GerMoonBank (GMB) · supabase/gmb_mode_developpement.sql
-- MODE DÉVELOPPEMENT : désactive les règles d'accès (RLS) sur toutes les tables.
-- -----------------------------------------------------------------------------
-- Supabase → SQL Editor → coller → Run. Rejouable sans risque.
-- Les règles (policies) restent enregistrées dans la base : elles sont seulement
-- mises en pause. gmb_mode_production.sql les réactive toutes d'un coup.
-- ATTENTION : sans RLS, toute personne qui dispose de la clé publiable (présente dans
-- le site public) peut lire et modifier les tables. N'y mettez que vos propres essais,
-- jamais les données de vrais clients.
-- =============================================================================
do $$
declare
  r record;
  n int := 0;
begin
  for r in select schemaname, tablename from pg_tables where schemaname in ('public', 'gmb_prive') and rowsecurity loop
    execute format('alter table %I.%I disable row level security', r.schemaname, r.tablename);
    n := n + 1;
  end loop;
  raise notice 'Mode développement : RLS désactivée sur % table(s).', n;
end
$$;

-- Droits d'accès du site (déjà accordés par défaut par Supabase ; rappelés ici pour
-- que le mode développement fonctionne dans tous les cas)
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to anon, authenticated;
grant usage, select on all sequences in schema public to anon, authenticated;

-- Exception : les coordonnées du compte qui reçoit les virements restent en lecture
-- seule pour le site. Elles ne changent que par le back-office (trésorerie, avec trace
-- au journal d'audit) ou par l'exploitant depuis le SQL Editor.
revoke insert, update, delete, truncate on public.parametres_banque from public, anon, authenticated;

select schemaname as schema, count(*) as tables, count(*) filter (where rowsecurity) as tables_encore_avec_rls
  from pg_tables where schemaname in ('public', 'gmb_prive') group by schemaname order by schemaname;
