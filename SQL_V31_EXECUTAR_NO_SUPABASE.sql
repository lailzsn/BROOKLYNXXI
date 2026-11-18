-- BROOKLYNXXI V31 - executar uma unica vez no SQL Editor do Supabase.
-- Mantenha backup do esquema antes de executar. Nao remove agendamentos nem tokens Push.
BEGIN;
ALTER TABLE brooklynxxi.profissionais ADD COLUMN IF NOT EXISTS duracao_padrao_min integer NOT NULL DEFAULT 30;
ALTER TABLE brooklynxxi.profissionais DROP CONSTRAINT IF EXISTS profissionais_duracao_padrao_v31_check;
ALTER TABLE brooklynxxi.profissionais ADD CONSTRAINT profissionais_duracao_padrao_v31_check CHECK (duracao_padrao_min BETWEEN 10 AND 360 AND duracao_padrao_min % 5 = 0);

CREATE OR REPLACE FUNCTION public.brooklynxxi_catalogo()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
 SELECT jsonb_build_object(
 'settings',(SELECT to_jsonb(c)-'id'-'atualizado_em' FROM brooklynxxi.configuracoes c WHERE id=true),
 'barbers',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',id,'name',nome,'active',ativo,'photo',foto_url,'duration',duracao_padrao_min) ORDER BY nome) FROM brooklynxxi.profissionais WHERE ativo),'[]'::jsonb),
 'services',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',id,'name',nome,'price',preco,'duration',duracao_min) ORDER BY nome) FROM brooklynxxi.servicos WHERE ativo),'[]'::jsonb),
 'occupied',COALESCE((SELECT jsonb_agg(jsonb_build_object('barber',profissional_id,'date',to_char(inicio AT TIME ZONE 'America/Sao_Paulo','YYYY-MM-DD'),'time',to_char(inicio AT TIME ZONE 'America/Sao_Paulo','HH24:MI'),'duration',EXTRACT(EPOCH FROM (fim-inicio))/60)) FROM brooklynxxi.agendamentos WHERE status IN ('pendente','confirmado') AND inicio >= now() AND inicio < now()+interval '45 days'),'[]'::jsonb)
 );
$function$;

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
 'status',CASE a.status WHEN 'pendente' THEN 'pending' WHEN 'confirmado' THEN 'confirmed' WHEN 'recusado' THEN 'rejected' ELSE 'cancelled' END,
 'source',a.origem) ORDER BY a.inicio DESC)
 FROM brooklynxxi.agendamentos a WHERE (v_admin OR a.profissional_id=v_barber) AND a.inicio>now()-interval '90 days'),'[]'::jsonb);
END;
$function$;

CREATE OR REPLACE FUNCTION public.brooklynxxi_reservar(p_profissional uuid, p_servico uuid, p_nome text, p_telefone text, p_inicio timestamp with time zone, p_consentimento boolean DEFAULT false, p_manual boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
 v_dur int; v_fim timestamptz; v_id uuid; v_origem text; v_status text;
 v_uid uuid:=auth.uid(); v_barber uuid; v_open time; v_close time;
 v_local timestamp; v_push_token text;
BEGIN
 IF length(trim(coalesce(p_nome,''))) < 2 OR length(trim(p_nome)) > 80 OR p_telefone !~ '^[0-9]{10,13}$' THEN RAISE EXCEPTION 'Nome ou telefone inválido'; END IF;
 IF p_inicio < now() OR p_inicio > now()+interval '180 days' THEN RAISE EXCEPTION 'Data fora do período permitido'; END IF;
 SELECT duracao_padrao_min INTO v_dur FROM brooklynxxi.profissionais WHERE id=p_profissional AND ativo;
 IF v_dur IS NULL OR NOT EXISTS(SELECT 1 FROM brooklynxxi.servicos WHERE id=p_servico AND ativo) THEN RAISE EXCEPTION 'Profissional ou serviço indisponível'; END IF;
 v_fim:=p_inicio+make_interval(mins=>v_dur);
 SELECT abertura,fechamento INTO v_open,v_close FROM brooklynxxi.configuracoes WHERE id=true;
 v_local:=p_inicio AT TIME ZONE 'America/Sao_Paulo';
 IF v_local::time<v_open OR (v_fim AT TIME ZONE 'America/Sao_Paulo')::date<>v_local::date OR (v_fim AT TIME ZONE 'America/Sao_Paulo')::time>v_close THEN RAISE EXCEPTION 'Fora do horário de atendimento'; END IF;
 IF p_manual THEN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Acesso não autorizado'; END IF;
  SELECT id INTO v_barber FROM brooklynxxi.profissionais WHERE auth_user_id=v_uid AND ativo;
  IF NOT EXISTS(SELECT 1 FROM brooklynxxi.administradores WHERE auth_user_id=v_uid) AND v_barber IS DISTINCT FROM p_profissional THEN RAISE EXCEPTION 'Sem permissão para essa agenda'; END IF;
  v_origem:=CASE WHEN EXISTS(SELECT 1 FROM brooklynxxi.administradores WHERE auth_user_id=v_uid) THEN 'administrador' ELSE 'barbeiro' END;
  v_status:='confirmado';
 ELSE
  IF NOT p_consentimento THEN RAISE EXCEPTION 'Consentimento obrigatório'; END IF;
  v_origem:='cliente'; v_status:='pendente';
 END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_profissional::text,0));
 IF EXISTS(SELECT 1 FROM brooklynxxi.agendamentos WHERE profissional_id=p_profissional AND status IN ('pendente','confirmado') AND inicio<v_fim AND fim>p_inicio) THEN RAISE EXCEPTION 'Horário indisponível'; END IF;
 INSERT INTO brooklynxxi.agendamentos(profissional_id,servico_id,cliente_nome,cliente_telefone,inicio,fim,status,origem,consentimento_whatsapp)
 VALUES(p_profissional,p_servico,trim(p_nome),p_telefone,p_inicio,v_fim,v_status,v_origem,p_consentimento) RETURNING id INTO v_id;
 IF NOT p_manual THEN
  v_push_token:=encode(extensions.gen_random_bytes(32),'hex');
  INSERT INTO brooklynxxi.push_tokens_clientes(agendamento_id,token_hash) VALUES(v_id,encode(extensions.digest(v_push_token,'sha256'),'hex'));
 END IF;
 RETURN jsonb_build_object('id',v_id,'status',v_status,'push_token',v_push_token);
END;
$function$;

CREATE OR REPLACE FUNCTION public.brooklynxxi_definir_duracao_barbeiro(p_profissional uuid,p_minutos integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_uid uuid:=auth.uid(); v_admin boolean;
BEGIN
 IF v_uid IS NULL THEN RAISE EXCEPTION 'Faça login'; END IF;
 IF p_minutos IS NULL OR p_minutos<10 OR p_minutos>360 OR p_minutos%5<>0 THEN RAISE EXCEPTION 'Escolha entre 10 e 360 minutos, em múltiplos de 5'; END IF;
 SELECT EXISTS(SELECT 1 FROM brooklynxxi.administradores WHERE auth_user_id=v_uid) INTO v_admin;
 IF NOT v_admin AND NOT EXISTS(SELECT 1 FROM brooklynxxi.profissionais WHERE id=p_profissional AND auth_user_id=v_uid AND ativo) THEN RAISE EXCEPTION 'Sem permissão'; END IF;
 UPDATE brooklynxxi.profissionais SET duracao_padrao_min=p_minutos WHERE id=p_profissional;
 IF NOT FOUND THEN RAISE EXCEPTION 'Barbeiro não encontrado'; END IF;
 RETURN jsonb_build_object('ok',true,'duration',p_minutos);
END;
$function$;

CREATE OR REPLACE FUNCTION public.brooklynxxi_alterar_duracao_agendamento(p_agendamento uuid,p_minutos integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_uid uuid:=auth.uid(); v_admin boolean; v_a brooklynxxi.agendamentos%ROWTYPE; v_fim timestamptz; v_close time;
BEGIN
 IF v_uid IS NULL THEN RAISE EXCEPTION 'Faça login'; END IF;
 IF p_minutos IS NULL OR p_minutos<10 OR p_minutos>360 OR p_minutos%5<>0 THEN RAISE EXCEPTION 'Escolha entre 10 e 360 minutos, em múltiplos de 5'; END IF;
 SELECT EXISTS(SELECT 1 FROM brooklynxxi.administradores WHERE auth_user_id=v_uid) INTO v_admin;
 -- Lock por barbeiro antes de ler o agendamento, igual ao fluxo de reserva.
 SELECT * INTO v_a FROM brooklynxxi.agendamentos WHERE id=p_agendamento;
 IF NOT FOUND THEN RAISE EXCEPTION 'Agendamento não encontrado'; END IF;
 IF NOT v_admin AND NOT EXISTS(SELECT 1 FROM brooklynxxi.profissionais WHERE id=v_a.profissional_id AND auth_user_id=v_uid AND ativo) THEN RAISE EXCEPTION 'Sem permissão'; END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_a.profissional_id::text,0));
 SELECT * INTO v_a FROM brooklynxxi.agendamentos WHERE id=p_agendamento FOR UPDATE;
 IF v_a.status NOT IN ('pendente','confirmado') THEN RAISE EXCEPTION 'Só é possível alterar atendimentos ativos'; END IF;
 IF v_a.inicio<=now() THEN RAISE EXCEPTION 'Não é possível alterar atendimento já iniciado'; END IF;
 v_fim:=v_a.inicio+make_interval(mins=>p_minutos);
 SELECT fechamento INTO v_close FROM brooklynxxi.configuracoes WHERE id=true;
 IF (v_fim AT TIME ZONE 'America/Sao_Paulo')::date<>(v_a.inicio AT TIME ZONE 'America/Sao_Paulo')::date OR (v_fim AT TIME ZONE 'America/Sao_Paulo')::time>v_close THEN RAISE EXCEPTION 'Duração ultrapassa o fechamento'; END IF;
 IF EXISTS(SELECT 1 FROM brooklynxxi.agendamentos a WHERE a.profissional_id=v_a.profissional_id AND a.id<>v_a.id AND a.status IN ('pendente','confirmado') AND a.inicio<v_fim AND a.fim>v_a.inicio) THEN RAISE EXCEPTION 'A duração conflita com outro agendamento'; END IF;
 UPDATE brooklynxxi.agendamentos SET fim=v_fim WHERE id=p_agendamento;
 RETURN jsonb_build_object('ok',true,'duration',p_minutos);
END;
$function$;
REVOKE ALL ON FUNCTION public.brooklynxxi_definir_duracao_barbeiro(uuid,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.brooklynxxi_alterar_duracao_agendamento(uuid,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.brooklynxxi_definir_duracao_barbeiro(uuid,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.brooklynxxi_alterar_duracao_agendamento(uuid,integer) TO authenticated;
COMMIT;
