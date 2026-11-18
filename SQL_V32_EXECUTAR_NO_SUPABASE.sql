-- BROOKLYNXXI V32 — quadro interno de horários (somente equipe autenticada)
-- Não altera agendamentos, funções Push ou duração da V31.
CREATE OR REPLACE FUNCTION public.brooklynxxi_quadro_horarios(p_dia date)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
 v_uid uuid := auth.uid();
 v_admin boolean;
 v_barber uuid;
BEGIN
 IF v_uid IS NULL THEN RAISE EXCEPTION 'Faça login'; END IF;
 SELECT EXISTS(SELECT 1 FROM brooklynxxi.administradores WHERE auth_user_id=v_uid) INTO v_admin;
 SELECT id INTO v_barber FROM brooklynxxi.profissionais WHERE auth_user_id=v_uid AND ativo LIMIT 1;
 IF NOT v_admin AND v_barber IS NULL THEN RAISE EXCEPTION 'Sem permissão'; END IF;
 IF p_dia IS NULL OR p_dia < CURRENT_DATE - 90 OR p_dia > CURRENT_DATE + 180 THEN
   RAISE EXCEPTION 'Data fora do período permitido';
 END IF;
 RETURN jsonb_build_object(
  'date',p_dia,
  'bookings',COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
     'id',a.id,'barber',a.profissional_id,'service',a.servico_id,
     'name',a.cliente_nome,
     'time',to_char(a.inicio AT TIME ZONE 'America/Sao_Paulo','HH24:MI'),
     'duration',EXTRACT(EPOCH FROM (a.fim-a.inicio))/60,
     'status',CASE a.status WHEN 'pendente' THEN 'pending' WHEN 'confirmado' THEN 'confirmed' ELSE 'cancelled' END
    ) ORDER BY a.inicio)
    FROM brooklynxxi.agendamentos a
    JOIN brooklynxxi.profissionais p ON p.id=a.profissional_id
    WHERE p.ativo AND a.status IN ('pendente','confirmado')
      AND (a.inicio AT TIME ZONE 'America/Sao_Paulo')::date=p_dia
  ),'[]'::jsonb)
 );
END;
$function$;
REVOKE ALL ON FUNCTION public.brooklynxxi_quadro_horarios(date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.brooklynxxi_quadro_horarios(date) FROM anon;
GRANT EXECUTE ON FUNCTION public.brooklynxxi_quadro_horarios(date) TO authenticated;
