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
