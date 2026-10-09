

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
