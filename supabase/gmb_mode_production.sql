-- =============================================================================
-- GerMoonBank (GMB) · supabase/gmb_mode_production.sql
-- Fin du développement : réactive les règles d'accès (RLS) sur toutes les tables
-- publiques. Les règles enregistrées par le schéma reprennent effet immédiatement.
-- -----------------------------------------------------------------------------
-- À exécuter avant d'accueillir de vrais clients : Supabase › SQL Editor › coller › Run.
-- Rejouable sans risque. Pour revenir en arrière : gmb_mode_developpement.sql.
-- Vérifiez ensuite les parcours (ouverture de compte, back-office, Espace client).
-- =============================================================================
do $$
declare
  r record;
  n int := 0;
begin
  for r in select schemaname, tablename from pg_tables where schemaname = 'public' and not rowsecurity loop
    execute format('alter table %I.%I enable row level security', r.schemaname, r.tablename);
    n := n + 1;
  end loop;
  raise notice 'Mode production : RLS réactivée sur % table(s).', n;
end
$$;

-- Compléments appliqués le 27/11/2026, après un essai à blanc de chaque espace
-- (visiteur, demandeur, client, back-office).

-- Compte de réception des premiers versements : lecture seule pour tous (affiché aux demandeurs)
drop policy if exists lecture_publique on public.parametres_banque;
create policy lecture_publique on public.parametres_banque for select to anon, authenticated using (true);

-- Réglages utiles aux espaces connectés (inactivité, nouveau bénéficiaire) ; les autres restent au back-office
drop policy if exists lecture_connectes on public.parametres_securite;
create policy lecture_connectes on public.parametres_securite for select to authenticated
  using (cle in ('inactivite_minutes', 'alerte_inactivite_minutes', 'mon_dossier_inactivite_minutes', 'nouveau_beneficiaire_plafond', 'nouveau_beneficiaire_heures'));

-- Bénéficiaire favori : le client ne modifie que la colonne « favori » de ses propres bénéficiaires
drop policy if exists titulaire_modifie on public.beneficiaires;
create policy titulaire_modifie on public.beneficiaires for update to authenticated
  using (client_id = gmb_prive.client_courant()) with check (client_id = gmb_prive.client_courant());
revoke update on public.beneficiaires from anon, authenticated;
grant update (favori) on public.beneficiaires to authenticated;

-- Mandats de prélèvement : seules la liste (blanche ou noire), le statut et la date de révocation se modifient
revoke update on public.mandats_prelevement from anon, authenticated;
grant update (liste, statut, revoque_le) on public.mandats_prelevement to authenticated;

-- TRUNCATE contourne les règles d'accès : retiré au site
revoke truncate on all tables in schema public from anon, authenticated;

select count(*) as tables_publiques, count(*) filter (where rowsecurity) as tables_avec_rls,
       (select count(*) from pg_policies where schemaname = 'public') as regles_actives
  from pg_tables where schemaname = 'public';
