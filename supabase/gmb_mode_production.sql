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

select count(*) as tables_publiques, count(*) filter (where rowsecurity) as tables_avec_rls,
       (select count(*) from pg_policies where schemaname = 'public') as regles_actives
  from pg_tables where schemaname = 'public';
