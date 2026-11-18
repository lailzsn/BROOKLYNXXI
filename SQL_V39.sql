BEGIN;
ALTER TABLE brooklynxxi.agendamentos DROP CONSTRAINT IF EXISTS agendamentos_status_check;
ALTER TABLE brooklynxxi.agendamentos ADD CONSTRAINT agendamentos_status_check CHECK (status IN ('pendente','confirmado','recusado','cancelado','expirado','finalizado'));
ALTER TABLE brooklynxxi.agendamentos ADD COLUMN IF NOT EXISTS acompanhamento_pendente boolean NOT NULL DEFAULT false, ADD COLUMN IF NOT EXISTS acompanhamento_verificado_em timestamptz, ADD COLUMN IF NOT EXISTS acompanhamento_verificado_por uuid;
UPDATE brooklynxxi.agendamentos SET status='expirado' WHERE status='pendente' AND inicio<=now();
UPDATE brooklynxxi.agendamentos SET status='finalizado' WHERE status='confirmado' AND fim<=now();
CREATE OR REPLACE FUNCTION public.brooklynxxi_atualizar_agenda_v39() RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO '' AS $$
 UPDATE brooklynxxi.agendamentos SET status='expirado', acompanhamento_pendente=true WHERE status='pendente' AND inicio<=now();
 UPDATE brooklynxxi.agendamentos SET status='finalizado' WHERE status='confirmado' AND fim<=now();
$$;
REVOKE ALL ON FUNCTION public.brooklynxxi_atualizar_agenda_v39() FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.brooklynxxi_verificar_expirado(p_id uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
BEGIN
 UPDATE brooklynxxi.agendamentos a SET acompanhamento_verificado_em=now(), acompanhamento_verificado_por=auth.uid() WHERE a.id=p_id AND a.status='expirado' AND a.acompanhamento_pendente AND a.acompanhamento_verificado_em IS NULL AND auth.uid() IS NOT NULL AND (EXISTS(SELECT 1 FROM brooklynxxi.administradores d WHERE d.auth_user_id=auth.uid()) OR EXISTS(SELECT 1 FROM brooklynxxi.profissionais p WHERE p.id=a.profissional_id AND p.auth_user_id=auth.uid() AND p.ativo));
 IF NOT FOUND THEN RAISE EXCEPTION 'Acompanhamento indisponível ou já verificado'; END IF;
END;$$;
REVOKE ALL ON FUNCTION public.brooklynxxi_verificar_expirado(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.brooklynxxi_verificar_expirado(uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public.brooklynxxi_agenda()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_uid uuid:=auth.uid(); v_admin boolean; v_barber uuid;
BEGIN
 IF v_uid IS NULL THEN RAISE EXCEPTION 'Faça login'; END IF;
 SELECT EXISTS(SELECT 1 FROM brooklynxxi.administradores WHERE auth_user_id=v_uid) INTO v_admin;
 SELECT id INTO v_barber FROM brooklynxxi.profissionais WHERE auth_user_id=v_uid AND ativo;
 IF NOT v_admin AND v_barber IS NULL THEN RAISE EXCEPTION 'Sem permissão'; END IF;
 RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
 'id',a.id,'barber',a.profissional_id,'service',a.servico_id,'name',a.cliente_nome,'phone',a.cliente_telefone,
 'date',to_char(a.inicio AT TIME ZONE 'America/Sao_Paulo','YYYY-MM-DD'),
 'time',to_char(a.inicio AT TIME ZONE 'America/Sao_Paulo','HH24:MI'),
 'duration',EXTRACT(EPOCH FROM (a.fim-a.inicio))/60,
 'end_time',to_char(a.fim AT TIME ZONE 'America/Sao_Paulo','HH24:MI'),
 'status',CASE a.status WHEN 'pendente' THEN 'pending' WHEN 'confirmado' THEN 'confirmed' WHEN 'recusado' THEN 'rejected' WHEN 'expirado' THEN 'expired' WHEN 'finalizado' THEN 'finished' ELSE 'cancelled' END,
 'followup',a.acompanhamento_pendente,'verified_at',a.acompanhamento_verificado_em,'source',a.origem) ORDER BY a.inicio DESC)
 FROM brooklynxxi.agendamentos a WHERE (v_admin OR a.profissional_id=v_barber) AND (a.inicio>now()-interval '90 days' OR (a.acompanhamento_pendente AND a.acompanhamento_verificado_em IS NULL))),'[]'::jsonb);
END;
$function$;

SELECT cron.schedule('brooklynxxi-agenda-v39','* * * * *','SELECT public.brooklynxxi_atualizar_agenda_v39();');
COMMIT;
