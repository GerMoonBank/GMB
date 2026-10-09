
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
