-- =============================================================================
-- GerMoonBank (GMB) · supabase/gmb_diagnostic_dossier.sql
-- DIAGNOSTIC D'UN DOSSIER, en lecture seule : ne modifie rien.
-- Remplacez, ligne « param », la référence du dossier (GMB-OUV-…) et l'adresse e-mail
-- du demandeur, puis exécutez dans le SQL Editor. La ligne 8 donne la prochaine action.
-- N'enregistrez jamais ce fichier dans le dépôt avec l'adresse d'une vraie personne.
-- =============================================================================
with param as (select 'GMB-OUV-00-000000'::text as ref, 'adresse@exemple.fr'::text as email),
u  as (select u.* from auth.users u, param where lower(u.email) = lower(param.email)),
d  as (select d.* from public.dossiers d, param where d.reference = param.ref),
v  as (select v.* from public.premiers_versements v join d on d.id = v.dossier_id),
c  as (select c.* from public.clients c join d on c.dossier_origine_id = d.id),
pc as (select count(*) filter (where x.statut not in ('validee', 'facultative')) as a_valider, count(*) filter (where x.statut in ('attendue', 'refusee')) as a_fournir
         from public.dossier_pieces x join d on d.id = x.dossier_id)
select ordre, etape, constat from (
  select 1 as ordre, 'Compte de connexion' as etape,
    coalesce((select case when email_confirmed_at is null then 'adresse NON confirmée' else 'adresse confirmée' end
                     || ', espace « ' || coalesce(raw_app_meta_data ->> 'espace', 'dossier') || ' »' from u), 'AUCUN compte avec cette adresse') as constat
  union all select 2, 'Dossier', coalesce((select reference || ' : ' || etat || coalesce(', déposé le ' || to_char(depose_le, 'DD/MM/YYYY HH24:MI'), ', jamais déposé') from d), 'AUCUN dossier avec cette référence')
  union all select 3, 'Pièces', coalesce((select string_agg(x.type || ' : ' || x.statut, ', ' order by x.type) from public.dossier_pieces x join d on d.id = x.dossier_id), '—')
  union all select 4, 'Premier versement', coalesce((select montant || ' € au nom de « ' || coalesce(nom_titulaire, '?') || ' » : ' || statut from v), 'non déclaré')
  union all select 5, 'Compte de réception', case when exists (select 1 from public.parametres_banque where cle = 'collecte_iban' and coalesce(valeur, '') <> '') then 'configuré' else 'NON configuré' end
  union all select 6, 'Administrateur', coalesce((select string_agg(email || case when actif then '' else ' (inactif)' end, ', ') from public.collaborateurs), 'AUCUN')
  union all select 7, 'Client et identifiant', coalesce((select 'identifiant ' || identifiant || ', ' || statut || case when auth_user_id is null then ', accès à activer' else ', accès activé' end from c), 'pas encore de client')
  union all select 8, '>>> PROCHAINE ACTION', (select case
      when not exists (select 1 from u) then 'Le demandeur doit créer son accès : public/inscription/index.html.'
      when (select raw_app_meta_data ->> 'espace' from u) = 'backoffice' then 'CONFLIT : cette adresse est celle d''un collaborateur du back-office. Créez l''administrateur avec une AUTRE adresse, et utilisez celle-ci uniquement comme client.'
      when not exists (select 1 from d) then 'Référence introuvable : le demandeur la retrouve dans l''Espace Mon Dossier (auth/mon-dossier.html), page Suivi.'
      when (select etat from d) = 'brouillon' then 'Demande non déposée : le demandeur se connecte à auth/mon-dossier.html, puis Suivi › « reprenez-la », jusqu''au bouton « Déposer ma demande ». Le back-office la voit dans Dossiers, filtre « Demandes non déposées ».'
      when (select etat from d) = 'incomplet' then 'Le demandeur doit fournir ou remplacer les pièces signalées : Espace Mon Dossier › Documents.'
      when (select etat from d) = 'refuse' then 'Dossier refusé : le motif est dans l''Espace Mon Dossier › Échanges.'
      when (select etat from d) in ('compte_ouvert', 'archive') and (select auth_user_id from c) is null then 'Compte ouvert : le client se connecte à auth/mon-dossier.html › Identifiant › « Afficher mon identifiant », puis « Activer mon accès » (code par e-mail, puis code secret saisi deux fois).'
      when (select etat from d) in ('compte_ouvert', 'archive') then 'Accès déjà activé : le client se connecte sur auth/connexion.html (code secret oublié : auth/code-secret.html).'
      when not exists (select 1 from public.collaborateurs where actif) then 'Aucun administrateur : créez-le (Authentication › Users › Add user, puis la commande du module d''installation, rubrique B, étape 9), avec une adresse différente de celle du client.'
      when not exists (select 1 from public.parametres_banque where cle = 'collecte_iban' and coalesce(valeur, '') <> '') then 'Compte de réception non renseigné : back-office › Trésorerie › « Renseigner le compte de réception ». Le demandeur pourra ensuite faire son premier versement.'
      when coalesce((select statut from v), 'aucun') = 'attendu' then 'Premier versement non reçu : le demandeur vire le montant indiqué sur le compte de réception, avec la référence ' || (select reference from d) || '. À réception sur le relevé, le back-office l''enregistre : bo/connexion.html › Trésorerie › « Reçu ».'
      when (select a_valider from pc) > 0 then 'Back-office : bo/connexion.html › Dossiers › ' || (select reference from d) || ' › « Prendre en charge », puis « Valider » chaque pièce.'
      else 'Back-office : bo/connexion.html › Dossiers › ' || (select reference from d) || ' › Décision › « Valider » : le compte est ouvert et l''identifiant créé.'
    end)
) t order by ordre;
