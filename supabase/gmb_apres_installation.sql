-- =============================================================================
-- GerMoonBank (GMB) · supabase/gmb_apres_installation.sql
-- CONTRÔLE DE L'INSTALLATION, en lecture seule : ce script ne modifie rien.
-- -----------------------------------------------------------------------------
-- Supabase › SQL Editor › requête vide › coller › Run, après une installation ou une
-- mise à niveau. Chaque ligne doit afficher « oui » ; sinon, la colonne « à faire »
-- dit quoi faire. Le tableau de bord du back-office (« État du service ») fait le même
-- contrôle et vérifie en plus la fonction serveur et les tâches quotidiennes.
--   Premier administrateur : module d'installation, rubrique B, étape 9
--     (ou : select gmb_prive.creer_administrateur('vous@exemple.fr', 'Votre nom');)
--   Compte de réception    : back-office › Trésorerie › « Renseigner le compte de réception »
-- =============================================================================
with version as (
  select coalesce((select substring(p.prosrc from '[0-9]{8}')::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'public' and p.proname = 'gmb_version'), 0) as v
)
select ordre, controle, resultat, a_faire from (
  select 1 as ordre, 'Version de la base' as controle,
         case when v >= 20261007 then 'oui : ' || v else 'non' || case when v > 0 then ' : ' || v else '' end end as resultat,
         case when v >= 20261007 then '' else 'Exécutez supabase/gmb_mise_a_niveau.sql (module d''installation, rubrique A).' end as a_faire
    from version
  union all
  select 2, 'Tables de la base', case when count(*) >= 83 then 'oui : ' || count(*) else 'non : ' || count(*) end,
         case when count(*) >= 83 then '' else 'Exécutez supabase/gmb_mise_a_niveau.sql.' end
    from pg_tables where schemaname = 'public'
  union all
  select 3, 'Administrateur actif', case when exists (select 1 from public.collaborateurs where actif) then 'oui' else 'non' end,
         case when exists (select 1 from public.collaborateurs where actif) then '' else 'Créez-le : module d''installation, rubrique B, étape 9.' end
  union all
  select 4, 'Compte de réception renseigné',
         case when exists (select 1 from public.parametres_banque where cle = 'collecte_iban' and coalesce(valeur, '') <> '') then 'oui' else 'non' end,
         case when exists (select 1 from public.parametres_banque where cle = 'collecte_iban' and coalesce(valeur, '') <> '') then ''
              else 'Back-office › Trésorerie › « Renseigner le compte de réception ».' end
  union all
  select 5, 'Espaces de stockage des pièces', case when count(*) >= 1 then 'oui : ' || count(*) else 'non' end,
         case when count(*) >= 1 then '' else 'Réinstallez la base : les espaces de stockage font partie de l''installation.' end
    from storage.buckets where id like 'gmb-%'
  union all
  select 6, 'Formules du catalogue', case when count(*) > 0 then 'oui : ' || count(*) else 'non' end,
         case when count(*) > 0 then '' else 'Réinstallez la base : le catalogue fait partie de l''installation.' end
    from public.formules
  union all
  select 7, 'Règles d''accès (RLS)',
         case when count(*) filter (where rowsecurity) = count(*) then 'actives sur toutes les tables (mode production)'
              when count(*) filter (where rowsecurity) = 0 then 'en pause (mode développement)'
              else 'actives sur ' || count(*) filter (where rowsecurity) || ' table(s) sur ' || count(*) end,
         case when count(*) filter (where rowsecurity) = count(*) then ''
              else 'Avant d''accueillir de vrais clients : supabase/gmb_mode_production.sql.' end
    from pg_tables where schemaname = 'public'
) t order by ordre;
