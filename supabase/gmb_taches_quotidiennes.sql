-- =============================================================================
-- GerMoonBank (GMB) · supabase/gmb_taches_quotidiennes.sql
-- Tâches quotidiennes — version 3
-- -----------------------------------------------------------------------------
-- Le script active lui-même l'extension pg_cron : aucun menu de Supabase à ouvrir.
-- À exécuter une fois dans le SQL Editor. Rejouable : une tâche du même nom est
-- remplacée, et un jour d'intérêts déjà calculé est ignoré.
-- =============================================================================

-- Extension des tâches planifiées : activée ici, sans passer par les menus de Supabase
create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;

-- Intérêts du Livret GMB : chaque nuit à 00 h 05 (heure UTC), pour la veille.
select cron.schedule('gmb-interets-livret', '5 0 * * *', $$select public.gmb_calculer_interets();$$);

-- Vérifier la tâche :          select jobname, schedule, active from cron.job;
-- Voir les dernières exécutions : select status, start_time, return_message
--                                from cron.job_run_details order by start_time desc limit 10;

-- Exécution des virements différés et permanents arrivés à échéance, puis de l'épargne
-- programmée : chaque jour à 6 h (UTC), avant l'ouverture des agences.
select cron.unschedule('gmb-executer-programmes') where exists (select 1 from cron.job where jobname = 'gmb-executer-programmes');
select cron.schedule('gmb-executer-programmes', '0 6 * * *', $$select public.gmb_executer_programmes()$$);

-- Prélèvement des échéances de prêt arrivées à date : chaque jour à 6 h 30 (UTC), après
-- l'exécution des virements programmés.
select cron.unschedule('gmb-prelever-echeances') where exists (select 1 from cron.job where jobname = 'gmb-prelever-echeances');
select cron.schedule('gmb-prelever-echeances', '30 6 * * *', $$select public.gmb_prelever_echeances()$$);

-- Cotisations mensuelles des formules : chaque jour à 5 h (UTC) ; chaque cotisation n'est
-- prélevée qu'une fois par mois, et une cotisation impayée est représentée chaque jour.
select cron.unschedule('gmb-prelever-cotisations') where exists (select 1 from cron.job where jobname = 'gmb-prelever-cotisations');
select cron.schedule('gmb-prelever-cotisations', '0 5 * * *', $$select public.gmb_prelever_cotisations()$$);
