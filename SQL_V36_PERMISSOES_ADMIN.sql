-- BROOKLYNXXI V36: permissões de administrador para barbeiros existentes.
-- Executar no SQL Editor antes de publicar a V36. Não altera agendamentos.
BEGIN;
CREATE OR REPLACE FUNCTION public.brooklynxxi_listar_permissoes()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $fn$
DECLARE v_uid uuid := auth.uid();
BEGIN
 IF v_uid IS NULL OR NOT EXISTS (SELECT 1 FROM brooklynxxi.administradores WHERE auth_user_id=v_uid) THEN
  RAISE EXCEPTION 'Somente administradores podem consultar permissões';
 END IF;
 RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id',p.id,'name',p.nome,'admin',EXISTS(SELECT 1 FROM brooklynxxi.administradores a WHERE a.auth_user_id=p.auth_user_id)) ORDER BY p.nome)
 FROM brooklynxxi.profissionais p WHERE p.auth_user_id IS NOT NULL), '[]'::jsonb);
END;$fn$;
CREATE OR REPLACE FUNCTION public.brooklynxxi_definir_admin_barbeiro(p_profissional uuid,p_admin boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $fn$
DECLARE v_uid uuid := auth.uid(); v_target uuid;
BEGIN
 IF v_uid IS NULL OR NOT EXISTS (SELECT 1 FROM brooklynxxi.administradores WHERE auth_user_id=v_uid) THEN
  RAISE EXCEPTION 'Somente administradores podem alterar permissões';
 END IF;
 SELECT auth_user_id INTO v_target FROM brooklynxxi.profissionais WHERE id=p_profissional;
 IF v_target IS NULL THEN RAISE EXCEPTION 'Barbeiro sem usuário de acesso vinculado'; END IF;
 IF p_admin IS NULL THEN RAISE EXCEPTION 'Permissão inválida'; END IF;
 -- Evita que o próprio administrador remova o seu acesso por engano.
 IF NOT p_admin AND v_target=v_uid THEN RAISE EXCEPTION 'Não é possível remover sua própria permissão administrativa'; END IF;
 IF p_admin THEN
  INSERT INTO brooklynxxi.administradores(auth_user_id) VALUES(v_target) ON CONFLICT (auth_user_id) DO NOTHING;
 ELSE
  DELETE FROM brooklynxxi.administradores WHERE auth_user_id=v_target;
 END IF;
 RETURN jsonb_build_object('ok',true,'admin',p_admin);
END;$fn$;
REVOKE ALL ON FUNCTION public.brooklynxxi_listar_permissoes() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.brooklynxxi_definir_admin_barbeiro(uuid,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.brooklynxxi_listar_permissoes() TO authenticated;
GRANT EXECUTE ON FUNCTION public.brooklynxxi_definir_admin_barbeiro(uuid,boolean) TO authenticated;
COMMIT;
