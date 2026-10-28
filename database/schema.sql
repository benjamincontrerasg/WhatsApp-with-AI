-- =============================================================================
--  Esquema de base de datos: WhatsApp con IA (tienda + pedidos + pagos)
--  Motor: PostgreSQL 16+ (probado en Neon, PG 18)
--  Exportado desde la base real; no incluye datos de pedidos ni de clientes.
--  Ejecutar completo en el SQL Editor de Neon (o con psql) sobre una base vacía.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS unaccent;

-- ---------------------------------------------------------------- Tipos -----
CREATE TYPE estado_pago    AS ENUM ('EN_PROCESO','APROBADO','RECHAZADO','REEMBOLSADO');
CREATE TYPE estado_pedido  AS ENUM ('BORRADOR','PENDIENTE_PAGO','PAGADO','PREPARANDO','LISTO_RETIRO',
                                    'ENVIADO','ENTREGADO','RETIRADO','CANCELADO','PAGO_RECHAZADO',
                                    'DEVOLUCION_SOLICITADA','DEVUELTO','REEMBOLSADO');
CREATE TYPE estado_reserva AS ENUM ('ACTIVA','CONSUMIDA','LIBERADA','EXPIRADA');
CREATE TYPE tipo_entrega   AS ENUM ('RETIRO','ENVIO');

-- --------------------------------------------------------------- Tablas -----
CREATE TABLE tiendas (
  id                     uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre                 text        NOT NULL,
  whatsapp_phone_number_id text      UNIQUE,
  moneda                 char(3)     NOT NULL DEFAULT 'CLP',
  reserva_minutos        integer     NOT NULL DEFAULT 15 CHECK (reserva_minutos  BETWEEN 1 AND 1440),
  borrador_minutos       integer     NOT NULL DEFAULT 30 CHECK (borrador_minutos BETWEEN 1 AND 1440),
  activa                 boolean     NOT NULL DEFAULT true,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE clientes (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  telefono   text        NOT NULL UNIQUE CHECK (telefono ~ '^[0-9]{8,15}$'),
  nombre     text,
  activo     boolean     NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE productos (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tienda_id   uuid        NOT NULL REFERENCES tiendas(id),
  nombre      text        NOT NULL CHECK (length(btrim(nombre)) > 0),
  descripcion text,
  categoria   text,
  imagen_url  text,
  activo      boolean     NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE variantes (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  producto_id      uuid        NOT NULL REFERENCES productos(id),
  sku              text        NOT NULL UNIQUE,
  talla            text,
  color            text,
  atributos        jsonb       NOT NULL DEFAULT '{}'::jsonb,
  precio           numeric     NOT NULL CHECK (precio >= 0),
  stock_fisico     integer     NOT NULL DEFAULT 0 CHECK (stock_fisico >= 0),
  stock_reservado  integer     NOT NULL DEFAULT 0 CHECK (stock_reservado >= 0),
  stock_disponible integer     GENERATED ALWAYS AS (stock_fisico - stock_reservado) STORED,
  activo           boolean     NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_reservado_no_excede_fisico CHECK (stock_reservado <= stock_fisico)
);

CREATE TABLE transiciones_pedido (
  desde estado_pedido NOT NULL,
  hasta estado_pedido NOT NULL,
  PRIMARY KEY (desde, hasta)
);

CREATE TABLE pedidos (
  id                       uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  numero                   bigint        GENERATED ALWAYS AS IDENTITY UNIQUE,
  tienda_id                uuid          NOT NULL REFERENCES tiendas(id),
  cliente_id               uuid          NOT NULL REFERENCES clientes(id),
  estado                   estado_pedido NOT NULL DEFAULT 'BORRADOR',
  tipo_entrega             tipo_entrega  NOT NULL DEFAULT 'RETIRO',
  moneda                   char(3)       NOT NULL,
  subtotal                 numeric       NOT NULL CHECK (subtotal >= 0),
  total                    numeric       NOT NULL CHECK (total >= 0),
  expira_en                timestamptz,
  confirmado_en            timestamptz,
  pagado_en                timestamptz,
  cancelado_en             timestamptz,
  cancelacion_motivo       text,
  confirmacion_enviada_en  timestamptz,
  mp_preference_id         text,
  mp_init_point            text,
  notas                    text,
  created_at               timestamptz   NOT NULL DEFAULT now(),
  updated_at               timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT ck_pedido_expira CHECK (
    estado <> ALL (ARRAY['BORRADOR','PENDIENTE_PAGO','PAGO_RECHAZADO']::estado_pedido[]) OR expira_en IS NOT NULL)
);

CREATE TABLE pedido_items (
  id              uuid    PRIMARY KEY DEFAULT gen_random_uuid(),
  pedido_id       uuid    NOT NULL REFERENCES pedidos(id) ON DELETE CASCADE,
  variante_id     uuid    NOT NULL REFERENCES variantes(id),
  cantidad        integer NOT NULL CHECK (cantidad > 0 AND cantidad <= 100),
  precio_unitario numeric NOT NULL CHECK (precio_unitario >= 0),
  producto_nombre text    NOT NULL,
  sku             text    NOT NULL,
  talla           text,
  color           text,
  subtotal        numeric GENERATED ALWAYS AS (cantidad::numeric * precio_unitario) STORED,
  UNIQUE (pedido_id, variante_id)
);

CREATE TABLE reservas_stock (
  id           uuid           PRIMARY KEY DEFAULT gen_random_uuid(),
  pedido_id    uuid           NOT NULL REFERENCES pedidos(id) ON DELETE CASCADE,
  variante_id  uuid           NOT NULL REFERENCES variantes(id),
  cantidad     integer        NOT NULL CHECK (cantidad > 0),
  estado       estado_reserva NOT NULL DEFAULT 'ACTIVA',
  expira_en    timestamptz    NOT NULL,
  consumida_en timestamptz,
  liberada_en  timestamptz,
  created_at   timestamptz    NOT NULL DEFAULT now(),
  UNIQUE (pedido_id, variante_id),
  CONSTRAINT ck_reserva_consumida CHECK ((estado = 'CONSUMIDA') = (consumida_en IS NOT NULL)),
  CONSTRAINT ck_reserva_liberada  CHECK ((estado = ANY (ARRAY['LIBERADA','EXPIRADA']::estado_reserva[])) = (liberada_en IS NOT NULL))
);

CREATE TABLE pagos (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  pedido_id         uuid        NOT NULL REFERENCES pedidos(id),
  mp_payment_id     text        NOT NULL UNIQUE CHECK (mp_payment_id ~ '^[0-9]{1,20}$'),
  estado            estado_pago NOT NULL DEFAULT 'EN_PROCESO',
  status_mp         text,
  status_detail     text,
  monto             numeric,
  moneda            char(3),
  metodo            text,
  procesado_en      timestamptz,
  requiere_revision boolean     NOT NULL DEFAULT false,
  revision_motivo   text,
  raw               jsonb,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE pedido_historial (
  id              bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  pedido_id       uuid          NOT NULL REFERENCES pedidos(id) ON DELETE CASCADE,
  estado_anterior estado_pedido,
  estado_nuevo    estado_pedido NOT NULL,
  motivo          text,
  actor           text,
  created_at      timestamptz   NOT NULL DEFAULT now()
);

CREATE TABLE webhook_eventos (
  id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  fuente      text        NOT NULL,
  evento_id   text        NOT NULL,
  payload     jsonb,
  recibido_en timestamptz NOT NULL DEFAULT now(),
  UNIQUE (fuente, evento_id)
);

CREATE TABLE error_log (
  id             bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ts             timestamptz NOT NULL DEFAULT now(),
  workflow_id    text,
  workflow_nombre text,
  nodo           text,
  mensaje        text,
  execution_id   text,
  execution_url  text,
  detalle        jsonb
);

-- Memoria del agente (n8n la crea sola si no existe; se deja por si prefieres crearla tú)
CREATE TABLE IF NOT EXISTS n8n_chat_histories (
  id         serial       PRIMARY KEY,
  session_id varchar(255) NOT NULL,
  message    jsonb        NOT NULL
);

-- -------------------------------------------------------------- Índices -----
CREATE INDEX ix_error_log_ts            ON error_log (ts DESC);
CREATE INDEX ix_historial_pedido        ON pedido_historial (pedido_id, created_at);
CREATE INDEX ix_items_variante          ON pedido_items (variante_id);
CREATE INDEX ix_pagos_pedido            ON pagos (pedido_id);
CREATE INDEX ix_pagos_revision          ON pagos (created_at) WHERE requiere_revision;
CREATE INDEX ix_pedidos_cliente_estado  ON pedidos (cliente_id, estado);
CREATE INDEX ix_pedidos_expiracion      ON pedidos (expira_en)
  WHERE estado = ANY (ARRAY['BORRADOR','PENDIENTE_PAGO','PAGO_RECHAZADO']::estado_pedido[]);
CREATE INDEX ix_productos_tienda_activo ON productos (tienda_id) WHERE activo;
CREATE INDEX ix_reservas_activas        ON reservas_stock (expira_en) WHERE estado = 'ACTIVA';
CREATE INDEX ix_reservas_variante       ON reservas_stock (variante_id) WHERE estado = 'ACTIVA';
CREATE INDEX ix_variantes_producto      ON variantes (producto_id) WHERE activo;
CREATE INDEX ix_webhook_eventos_fecha   ON webhook_eventos (recibido_en);
CREATE UNIQUE INDEX ux_pedido_borrador_por_cliente ON pedidos (cliente_id) WHERE estado = 'BORRADOR';
CREATE UNIQUE INDEX ux_variantes_atributos ON variantes (producto_id, COALESCE(talla, ''), COALESCE(color, ''));

-- ------------------------------------------- Transiciones válidas (datos) ---
INSERT INTO transiciones_pedido (desde, hasta) VALUES
  ('BORRADOR','CANCELADO'), ('BORRADOR','PENDIENTE_PAGO'),
  ('CANCELADO','PAGADO'),
  ('DEVOLUCION_SOLICITADA','DEVUELTO'), ('DEVUELTO','REEMBOLSADO'),
  ('ENTREGADO','DEVOLUCION_SOLICITADA'), ('ENTREGADO','REEMBOLSADO'),
  ('ENVIADO','ENTREGADO'), ('ENVIADO','REEMBOLSADO'),
  ('LISTO_RETIRO','REEMBOLSADO'), ('LISTO_RETIRO','RETIRADO'),
  ('PAGADO','PREPARANDO'), ('PAGADO','REEMBOLSADO'),
  ('PAGO_RECHAZADO','CANCELADO'), ('PAGO_RECHAZADO','PAGADO'), ('PAGO_RECHAZADO','PENDIENTE_PAGO'),
  ('PENDIENTE_PAGO','CANCELADO'), ('PENDIENTE_PAGO','PAGADO'), ('PENDIENTE_PAGO','PAGO_RECHAZADO'),
  ('PREPARANDO','ENVIADO'), ('PREPARANDO','LISTO_RETIRO'), ('PREPARANDO','REEMBOLSADO'),
  ('RETIRADO','DEVOLUCION_SOLICITADA'), ('RETIRADO','REEMBOLSADO');

-- ------------------------------------------------------ Funciones base ------
CREATE OR REPLACE FUNCTION fn_try_uuid(p text) RETURNS uuid LANGUAGE plpgsql IMMUTABLE AS $function$
BEGIN RETURN p::uuid; EXCEPTION WHEN others THEN RETURN NULL; END $function$;

CREATE OR REPLACE FUNCTION fn_like_escape(p text) RETURNS text LANGUAGE sql IMMUTABLE AS
$function$ SELECT replace(replace(replace(p, '\', '\\'), '%', '\%'), '_', '\_') $function$;

CREATE OR REPLACE FUNCTION fn_tienda_default() RETURNS uuid LANGUAGE sql STABLE AS
$function$ SELECT id FROM tiendas WHERE activa ORDER BY created_at LIMIT 1 $function$;

-- ------------------------------------------------------------ Triggers ------
CREATE OR REPLACE FUNCTION trg_set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN NEW.updated_at := now(); RETURN NEW; END $function$;

CREATE OR REPLACE FUNCTION trg_pedidos_validar_transicion() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
  IF NEW.estado IS DISTINCT FROM OLD.estado
     AND NOT EXISTS (SELECT 1 FROM transiciones_pedido t WHERE t.desde = OLD.estado AND t.hasta = NEW.estado)
  THEN
    RAISE EXCEPTION 'TRANSICION_INVALIDA: % -> %', OLD.estado, NEW.estado USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION trg_pedidos_historial() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO pedido_historial (pedido_id, estado_anterior, estado_nuevo, motivo, actor)
    VALUES (NEW.id, NULL, NEW.estado, 'CREACION', COALESCE(NULLIF(current_setting('app.actor', true), ''), 'sistema'));
  ELSE
    INSERT INTO pedido_historial (pedido_id, estado_anterior, estado_nuevo, motivo, actor)
    VALUES (NEW.id, OLD.estado, NEW.estado,
            NULLIF(current_setting('app.motivo', true), ''),
            COALESCE(NULLIF(current_setting('app.actor', true), ''), 'manual'));
  END IF;
  RETURN NEW;
END $function$;

CREATE TRIGGER set_updated_at BEFORE UPDATE ON tiendas   FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON clientes  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON productos FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON variantes FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON pedidos   FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON pagos     FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
CREATE TRIGGER pedidos_validar_transicion BEFORE UPDATE OF estado ON pedidos
  FOR EACH ROW EXECUTE FUNCTION trg_pedidos_validar_transicion();
CREATE TRIGGER pedidos_historial_ins AFTER INSERT ON pedidos
  FOR EACH ROW EXECUTE FUNCTION trg_pedidos_historial();
CREATE TRIGGER pedidos_historial_upd AFTER UPDATE ON pedidos
  FOR EACH ROW WHEN (OLD.estado IS DISTINCT FROM NEW.estado) EXECUTE FUNCTION trg_pedidos_historial();

-- ------------------------------------------------- Funciones de negocio -----
CREATE OR REPLACE FUNCTION fn_cambiar_estado_pedido(p_pedido uuid, p_nuevo estado_pedido, p_motivo text DEFAULT NULL, p_actor text DEFAULT 'sistema')
RETURNS void LANGUAGE plpgsql AS $function$
BEGIN
  PERFORM set_config('app.motivo', COALESCE(p_motivo, ''), true);
  PERFORM set_config('app.actor',  COALESCE(p_actor, 'sistema'), true);
  -- El trigger trg_pedidos_validar_transicion rechaza transiciones inválidas
  UPDATE pedidos SET
    estado = p_nuevo,
    pagado_en          = CASE WHEN p_nuevo = 'PAGADO'    THEN now() ELSE pagado_en END,
    cancelado_en       = CASE WHEN p_nuevo = 'CANCELADO' THEN now() ELSE cancelado_en END,
    cancelacion_motivo = CASE WHEN p_nuevo = 'CANCELADO' THEN p_motivo ELSE cancelacion_motivo END
  WHERE id = p_pedido AND estado <> p_nuevo;
END $function$;

CREATE OR REPLACE FUNCTION fn_liberar_reservas(p_pedido uuid, p_estado estado_reserva DEFAULT 'LIBERADA')
RETURNS integer LANGUAGE plpgsql AS $function$
DECLARE r record; n int := 0;
BEGIN
  IF p_estado NOT IN ('LIBERADA','EXPIRADA') THEN RAISE EXCEPTION 'estado de liberacion invalido'; END IF;
  FOR r IN SELECT id, variante_id, cantidad FROM reservas_stock
           WHERE pedido_id = p_pedido AND estado = 'ACTIVA'
           ORDER BY variante_id FOR UPDATE
  LOOP
    UPDATE reservas_stock SET estado = p_estado, liberada_en = now() WHERE id = r.id;
    UPDATE variantes SET stock_reservado = stock_reservado - r.cantidad WHERE id = r.variante_id;
    n := n + 1;
  END LOOP;
  RETURN n;
END $function$;

CREATE OR REPLACE FUNCTION fn_pedido_json(p_pedido uuid)
RETURNS jsonb LANGUAGE sql STABLE AS $function$
  SELECT jsonb_build_object(
    'pedido_id', p.id, 'numero', p.numero, 'estado', p.estado, 'telefono', c.telefono,
    'subtotal', p.subtotal, 'total', p.total, 'moneda', trim(p.moneda), 'expira_en', p.expira_en,
    'mp_preference_id', p.mp_preference_id, 'mp_init_point', p.mp_init_point,
    'items', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'variante_id', i.variante_id, 'sku', i.sku, 'producto', i.producto_nombre,
        'talla', i.talla, 'color', i.color, 'cantidad', i.cantidad,
        'precio_unitario', i.precio_unitario, 'subtotal', i.subtotal) ORDER BY i.producto_nombre, i.sku)
      FROM pedido_items i WHERE i.pedido_id = p.id), '[]'::jsonb))
  FROM pedidos p JOIN clientes c ON c.id = p.cliente_id WHERE p.id = p_pedido
$function$;

CREATE OR REPLACE FUNCTION fn_consultar_productos(p_busqueda text DEFAULT NULL, p_tienda_id uuid DEFAULT NULL, p_limite integer DEFAULT 10)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $function$
DECLARE
  v_tienda uuid := COALESCE(p_tienda_id, fn_tienda_default());
  v_q text := NULLIF(btrim(left(p_busqueda, 80)), '');
  v_tokens text[] := '{}';
BEGIN
  IF v_q IS NOT NULL THEN
    -- tokens normalizados (sin tildes, minúsculas, plural simple "camisetas" -> "camiseta")
    SELECT COALESCE(array_agg(regexp_replace(t, '(es|s)$', '')), '{}') INTO v_tokens
    FROM unnest(string_to_array(unaccent(lower(v_q)), ' ')) AS t WHERE length(t) >= 3;
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(x ORDER BY x->>'nombre') FROM (
      SELECT jsonb_build_object(
        'producto_id', p.id, 'nombre', p.nombre, 'descripcion', p.descripcion, 'categoria', p.categoria,
        'precio_desde', MIN(v.precio), 'precio_hasta', MAX(v.precio),
        'moneda', trim((SELECT moneda FROM tiendas WHERE id = p.tienda_id)),
        'unidades_disponibles', COALESCE(SUM(v.stock_disponible), 0)::int) AS x
      FROM productos p
      JOIN variantes v ON v.producto_id = p.id AND v.activo
      WHERE p.tienda_id = v_tienda AND p.activo
        AND NOT EXISTS (
          SELECT 1 FROM unnest(v_tokens) tk
          WHERE unaccent(lower(p.nombre || ' ' || COALESCE(p.categoria,'') || ' ' || COALESCE(p.descripcion,'')))
                NOT LIKE '%' || fn_like_escape(tk) || '%')
      GROUP BY p.id
      ORDER BY p.nombre
      LIMIT LEAST(GREATEST(COALESCE(p_limite, 10), 1), 20)
    ) s), '[]'::jsonb);
END $function$;

CREATE OR REPLACE FUNCTION fn_consultar_variantes(p_producto_id text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $function$
DECLARE v_id uuid := fn_try_uuid(p_producto_id); v_prod record;
BEGIN
  IF v_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'codigo', 'PRODUCTO_ID_INVALIDO'); END IF;
  SELECT p.id, p.nombre, trim(t.moneda) AS moneda INTO v_prod
  FROM productos p JOIN tiendas t ON t.id = p.tienda_id WHERE p.id = v_id AND p.activo;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'codigo', 'PRODUCTO_NO_ENCONTRADO'); END IF;
  RETURN jsonb_build_object('ok', true, 'producto_id', v_prod.id, 'producto', v_prod.nombre, 'moneda', v_prod.moneda,
    'variantes', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'variante_id', v.id, 'sku', v.sku, 'talla', v.talla, 'color', v.color, 'atributos', v.atributos,
        'precio', v.precio, 'stock_disponible', v.stock_disponible) ORDER BY v.color, v.talla, v.sku)
      FROM variantes v WHERE v.producto_id = v_id AND v.activo), '[]'::jsonb));
END $function$;

CREATE OR REPLACE FUNCTION fn_consultar_stock(p_variante_id text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $function$
DECLARE v_id uuid := fn_try_uuid(p_variante_id); v record;
BEGIN
  IF v_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'codigo', 'VARIANTE_ID_INVALIDO'); END IF;
  SELECT v2.id, v2.sku, v2.talla, v2.color, v2.precio, v2.stock_disponible, p.nombre INTO v
  FROM variantes v2 JOIN productos p ON p.id = v2.producto_id WHERE v2.id = v_id AND v2.activo AND p.activo;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'codigo', 'VARIANTE_NO_ENCONTRADA'); END IF;
  RETURN jsonb_build_object('ok', true, 'variante_id', v.id, 'producto', v.nombre, 'sku', v.sku,
    'talla', v.talla, 'color', v.color, 'precio', v.precio,
    'stock_disponible', v.stock_disponible, 'disponible', v.stock_disponible > 0);
END $function$;

CREATE OR REPLACE FUNCTION fn_preparar_pedido(p_telefono text, p_nombre text, p_variante_id text, p_cantidad integer, p_tienda_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $function$
DECLARE
  v_vid uuid := fn_try_uuid(p_variante_id);
  v_cliente uuid; v_var record; v_pedido uuid; v_old uuid; v_tienda record;
BEGIN
  IF p_telefono IS NULL OR p_telefono !~ '^[0-9]{8,15}$' THEN
    RETURN jsonb_build_object('ok', false, 'codigo', 'TELEFONO_INVALIDO'); END IF;
  IF v_vid IS NULL THEN RETURN jsonb_build_object('ok', false, 'codigo', 'VARIANTE_ID_INVALIDO'); END IF;
  IF p_cantidad IS NULL OR p_cantidad < 1 OR p_cantidad > 20 THEN
    RETURN jsonb_build_object('ok', false, 'codigo', 'CANTIDAD_INVALIDA', 'maximo', 20); END IF;

  SELECT v.id, v.sku, v.talla, v.color, v.precio, v.stock_disponible, p.nombre AS producto, p.tienda_id INTO v_var
  FROM variantes v JOIN productos p ON p.id = v.producto_id
  WHERE v.id = v_vid AND v.activo AND p.activo AND p.tienda_id = COALESCE(p_tienda_id, p.tienda_id);
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'codigo', 'VARIANTE_NO_ENCONTRADA'); END IF;

  -- Chequeo informativo (la garantía real es la reserva atómica al confirmar)
  IF v_var.stock_disponible < p_cantidad THEN
    RETURN jsonb_build_object('ok', false, 'codigo', 'SIN_STOCK', 'stock_disponible', v_var.stock_disponible);
  END IF;

  SELECT id, trim(moneda) AS moneda, borrador_minutos INTO v_tienda FROM tiendas WHERE id = v_var.tienda_id;

  -- Upsert del cliente: el ON CONFLICT bloquea la fila hasta el fin de la transacción,
  -- serializando "preparar pedido" simultáneos del mismo número.
  INSERT INTO clientes (telefono, nombre) VALUES (p_telefono, NULLIF(btrim(left(p_nombre, 100)), ''))
  ON CONFLICT (telefono) DO UPDATE SET nombre = COALESCE(EXCLUDED.nombre, clientes.nombre)
  RETURNING id INTO v_cliente;

  -- Reemplaza el borrador anterior del cliente (si existe)
  FOR v_old IN SELECT id FROM pedidos WHERE cliente_id = v_cliente AND estado = 'BORRADOR' FOR UPDATE LOOP
    PERFORM fn_cambiar_estado_pedido(v_old, 'CANCELADO', 'REEMPLAZADO_POR_NUEVO_BORRADOR', 'sistema');
  END LOOP;

  INSERT INTO pedidos (tienda_id, cliente_id, estado, moneda, subtotal, total, expira_en)
  VALUES (v_tienda.id, v_cliente, 'BORRADOR', v_tienda.moneda,
          v_var.precio * p_cantidad, v_var.precio * p_cantidad,
          now() + make_interval(mins => v_tienda.borrador_minutos))
  RETURNING id INTO v_pedido;

  INSERT INTO pedido_items (pedido_id, variante_id, cantidad, precio_unitario, producto_nombre, sku, talla, color)
  VALUES (v_pedido, v_var.id, p_cantidad, v_var.precio, v_var.producto, v_var.sku, v_var.talla, v_var.color);

  RETURN jsonb_build_object('ok', true, 'codigo', 'BORRADOR_CREADO', 'pedido_id', v_pedido,
    'nota', 'El pedido NO esta confirmado ni pagado. El sistema enviara al cliente un resumen con botones Confirmar/Cancelar.');
END $function$;

CREATE OR REPLACE FUNCTION fn_pedido_pendiente_confirmacion(p_telefono text)
RETURNS jsonb LANGUAGE sql STABLE AS $function$
  SELECT fn_pedido_json(p.id)
  FROM pedidos p JOIN clientes c ON c.id = p.cliente_id
  WHERE c.telefono = p_telefono AND p.estado = 'BORRADOR'
    AND p.confirmacion_enviada_en IS NULL AND p.expira_en > now()
  ORDER BY p.created_at DESC LIMIT 1
$function$;

CREATE OR REPLACE FUNCTION fn_marcar_confirmacion_enviada(p_pedido_id text)
RETURNS boolean LANGUAGE plpgsql AS $function$
DECLARE n int;
BEGIN
  UPDATE pedidos SET confirmacion_enviada_en = now()
  WHERE id = fn_try_uuid(p_pedido_id) AND confirmacion_enviada_en IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT; RETURN n > 0;
END $function$;

CREATE OR REPLACE FUNCTION fn_pedidos_cliente(p_telefono text, p_limite integer DEFAULT 5)
RETURNS jsonb LANGUAGE sql STABLE AS $function$
  SELECT COALESCE(jsonb_agg(x ORDER BY (x->>'creado')::timestamptz DESC), '[]'::jsonb) FROM (
    SELECT jsonb_build_object('pedido_id', p.id, 'numero', p.numero, 'estado', p.estado, 'total', p.total,
                              'moneda', trim(p.moneda), 'creado', p.created_at) AS x
    FROM pedidos p JOIN clientes c ON c.id = p.cliente_id
    WHERE c.telefono = p_telefono
    ORDER BY p.created_at DESC LIMIT LEAST(GREATEST(COALESCE(p_limite,5),1),10)) s
$function$;

CREATE OR REPLACE FUNCTION fn_obtener_pedido(p_pedido_id text, p_telefono text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $function$
DECLARE v_id uuid := fn_try_uuid(p_pedido_id);
BEGIN
  IF v_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'codigo', 'ID_INVALIDO'); END IF;
  IF NOT EXISTS (SELECT 1 FROM pedidos p JOIN clientes c ON c.id = p.cliente_id
                 WHERE p.id = v_id AND c.telefono = p_telefono) THEN
    RETURN jsonb_build_object('ok', false, 'codigo', 'PEDIDO_NO_ENCONTRADO'); END IF;
  RETURN jsonb_build_object('ok', true) || (fn_pedido_json(v_id) - 'mp_init_point' - 'mp_preference_id' - 'telefono');
END $function$;

CREATE OR REPLACE FUNCTION fn_cancelar_pedido(p_pedido_id text, p_telefono text, p_motivo text DEFAULT 'CANCELADO_POR_CLIENTE')
RETURNS jsonb LANGUAGE plpgsql AS $function$
DECLARE v_id uuid := fn_try_uuid(p_pedido_id); v_ped pedidos%ROWTYPE; n int;
BEGIN
  IF v_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'codigo', 'ID_INVALIDO'); END IF;
  SELECT p.* INTO v_ped FROM pedidos p JOIN clientes c ON c.id = p.cliente_id
  WHERE p.id = v_id AND c.telefono = p_telefono FOR UPDATE OF p;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'codigo', 'PEDIDO_NO_ENCONTRADO'); END IF;

  IF v_ped.estado = 'CANCELADO' THEN
    RETURN jsonb_build_object('ok', true, 'codigo', 'YA_CANCELADO', 'numero', v_ped.numero);
  END IF;
  IF v_ped.estado NOT IN ('BORRADOR','PENDIENTE_PAGO','PAGO_RECHAZADO') THEN
    RETURN jsonb_build_object('ok', false, 'codigo', 'NO_CANCELABLE', 'estado', v_ped.estado, 'numero', v_ped.numero);
  END IF;

  n := fn_liberar_reservas(v_id, 'LIBERADA');
  PERFORM fn_cambiar_estado_pedido(v_id, 'CANCELADO', left(COALESCE(p_motivo,'CANCELADO_POR_CLIENTE'), 100), 'cliente');
  RETURN jsonb_build_object('ok', true, 'codigo', 'CANCELADO', 'numero', v_ped.numero, 'reservas_liberadas', n);
END $function$;

CREATE OR REPLACE FUNCTION fn_confirmar_pedido(p_pedido_id text, p_telefono text)
RETURNS jsonb LANGUAGE plpgsql AS $function$
DECLARE
  v_id uuid := fn_try_uuid(p_pedido_id);
  v_ped pedidos%ROWTYPE; v_min int; v_expira timestamptz; v_it record;
BEGIN
  IF v_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'codigo', 'ID_INVALIDO'); END IF;

  -- Lock del pedido + verificación de propiedad. "No existe" y "es de otro" devuelven lo mismo
  -- a propósito (no se filtra información sobre pedidos ajenos).
  SELECT p.* INTO v_ped FROM pedidos p JOIN clientes c ON c.id = p.cliente_id
  WHERE p.id = v_id AND c.telefono = p_telefono FOR UPDATE OF p;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'codigo', 'PEDIDO_NO_ENCONTRADO'); END IF;

  -- Idempotencia: doble toque del botón
  IF v_ped.estado IN ('PENDIENTE_PAGO','PAGO_RECHAZADO') THEN
    IF v_ped.expira_en <= now() THEN
      RETURN jsonb_build_object('ok', false, 'codigo', 'EXPIRADO', 'numero', v_ped.numero);
    END IF;
    RETURN jsonb_build_object('ok', true, 'codigo', 'YA_CONFIRMADO') || fn_pedido_json(v_id);
  ELSIF v_ped.estado = 'PAGADO' THEN
    RETURN jsonb_build_object('ok', false, 'codigo', 'YA_PAGADO', 'numero', v_ped.numero);
  ELSIF v_ped.estado = 'CANCELADO' THEN
    RETURN jsonb_build_object('ok', false, 'codigo', 'CANCELADO', 'numero', v_ped.numero);
  ELSIF v_ped.estado <> 'BORRADOR' THEN
    RETURN jsonb_build_object('ok', false, 'codigo', 'ESTADO_INVALIDO', 'estado', v_ped.estado);
  END IF;

  -- BORRADOR vencido
  IF v_ped.expira_en <= now() THEN
    PERFORM fn_cambiar_estado_pedido(v_id, 'CANCELADO', 'EXPIRADO', 'sistema');
    RETURN jsonb_build_object('ok', false, 'codigo', 'EXPIRADO', 'numero', v_ped.numero);
  END IF;

  SELECT reserva_minutos INTO v_min FROM tiendas WHERE id = v_ped.tienda_id;
  v_expira := now() + make_interval(mins => v_min);

  -- Reserva ATÓMICA: el UPDATE condicional comprueba y modifica en una sola sentencia.
  -- Bajo READ COMMITTED, si dos transacciones compiten por la última unidad, la segunda
  -- espera el lock de fila, re-evalúa el WHERE con el valor ya actualizado y no coincide.
  BEGIN  -- sub-transacción: si falla un ítem, se revierte todo lo reservado antes
    FOR v_it IN SELECT variante_id, cantidad FROM pedido_items WHERE pedido_id = v_id ORDER BY variante_id LOOP
      UPDATE variantes SET stock_reservado = stock_reservado + v_it.cantidad
      WHERE id = v_it.variante_id AND activo AND stock_fisico - stock_reservado >= v_it.cantidad;
      IF NOT FOUND THEN RAISE EXCEPTION 'SIN_STOCK'; END IF;

      INSERT INTO reservas_stock (pedido_id, variante_id, cantidad, estado, expira_en)
      VALUES (v_id, v_it.variante_id, v_it.cantidad, 'ACTIVA', v_expira);
    END LOOP;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM = 'SIN_STOCK' THEN
      RETURN jsonb_build_object('ok', false, 'codigo', 'SIN_STOCK', 'numero', v_ped.numero);
    END IF;
    RAISE;
  END;

  UPDATE pedidos SET expira_en = v_expira, confirmado_en = now() WHERE id = v_id;
  PERFORM fn_cambiar_estado_pedido(v_id, 'PENDIENTE_PAGO', 'CONFIRMADO_POR_CLIENTE', 'cliente');
  RETURN jsonb_build_object('ok', true, 'codigo', 'CONFIRMADO') || fn_pedido_json(v_id);
END $function$;

CREATE OR REPLACE FUNCTION fn_registrar_preferencia(p_pedido_id text, p_pref_id text, p_init_point text)
RETURNS jsonb LANGUAGE plpgsql AS $function$
DECLARE v_id uuid := fn_try_uuid(p_pedido_id); v_ped pedidos%ROWTYPE;
BEGIN
  SELECT * INTO v_ped FROM pedidos WHERE id = v_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'codigo', 'PEDIDO_NO_ENCONTRADO'); END IF;
  IF v_ped.estado NOT IN ('PENDIENTE_PAGO','PAGO_RECHAZADO') THEN
    RETURN jsonb_build_object('ok', false, 'codigo', 'ESTADO_INVALIDO', 'estado', v_ped.estado); END IF;
  UPDATE pedidos SET mp_preference_id = COALESCE(mp_preference_id, p_pref_id),
                     mp_init_point    = COALESCE(mp_init_point, p_init_point)
  WHERE id = v_id;
  RETURN jsonb_build_object('ok', true, 'codigo', 'PREFERENCIA_REGISTRADA') || fn_pedido_json(v_id);
END $function$;

CREATE OR REPLACE FUNCTION fn_registrar_webhook(p_fuente text, p_evento_id text, p_payload jsonb DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql AS $function$
DECLARE n int;
BEGIN
  INSERT INTO webhook_eventos (fuente, evento_id, payload) VALUES (p_fuente, p_evento_id, p_payload)
  ON CONFLICT (fuente, evento_id) DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n > 0;            -- true = evento nuevo, false = duplicado
END $function$;

CREATE OR REPLACE FUNCTION fn_limpiar_webhook_eventos(p_dias integer DEFAULT 30)
RETURNS integer LANGUAGE plpgsql AS $function$
DECLARE n int;
BEGIN
  DELETE FROM webhook_eventos WHERE recibido_en < now() - make_interval(days => p_dias);
  GET DIAGNOSTICS n = ROW_COUNT; RETURN n;
END $function$;

CREATE OR REPLACE FUNCTION fn_expirar_reservas(p_limite integer DEFAULT 100, p_gracia interval DEFAULT '00:01:00')
RETURNS TABLE(pedido_id uuid, numero bigint, telefono text, estado_anterior estado_pedido, reservas_liberadas integer)
LANGUAGE plpgsql AS $function$
DECLARE v record; n int;
BEGIN
  FOR v IN
    SELECT p.id AS pid, p.numero AS num, p.estado AS est, c.telefono AS tel
    FROM pedidos p JOIN clientes c ON c.id = p.cliente_id
    WHERE p.estado IN ('BORRADOR','PENDIENTE_PAGO','PAGO_RECHAZADO')
      AND p.expira_en < now() - p_gracia
    ORDER BY p.expira_en LIMIT p_limite
    FOR UPDATE OF p SKIP LOCKED
  LOOP
    n := fn_liberar_reservas(v.pid, 'EXPIRADA');
    PERFORM fn_cambiar_estado_pedido(v.pid, 'CANCELADO', 'EXPIRADO', 'sistema');
    pedido_id := v.pid; numero := v.num; telefono := v.tel; estado_anterior := v.est; reservas_liberadas := n;
    RETURN NEXT;
  END LOOP;
END $function$;

CREATE OR REPLACE FUNCTION fn_procesar_pago(p_mp_payment_id text, p_status text, p_status_detail text, p_external_reference text, p_monto numeric, p_moneda text, p_metodo text, p_raw jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $function$
DECLARE
  v_pedido_id uuid := fn_try_uuid(p_external_reference);
  v_ped pedidos%ROWTYPE; v_pago pagos%ROWTYPE;
  v_estado estado_pago; v_tel text; v_it record; v_ok boolean; n int;
  v_base jsonb;
BEGIN
  IF p_mp_payment_id IS NULL OR p_mp_payment_id !~ '^[0-9]{1,20}$' THEN
    RETURN jsonb_build_object('ok', false, 'codigo', 'PAYMENT_ID_INVALIDO', 'notificar', false, 'alerta_admin', true);
  END IF;
  IF v_pedido_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'codigo', 'EXTERNAL_REFERENCE_INVALIDA', 'notificar', false,
                              'alerta_admin', true, 'payment_id', p_mp_payment_id);
  END IF;

  v_estado := CASE lower(COALESCE(p_status, ''))
    WHEN 'approved' THEN 'APROBADO'
    WHEN 'rejected' THEN 'RECHAZADO' WHEN 'cancelled' THEN 'RECHAZADO'
    WHEN 'refunded' THEN 'REEMBOLSADO' WHEN 'charged_back' THEN 'REEMBOLSADO'
    ELSE 'EN_PROCESO' END;

  -- 1) lock del pedido (siempre primero)
  SELECT * INTO v_ped FROM pedidos WHERE id = v_pedido_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'codigo', 'PEDIDO_NO_ENCONTRADO', 'notificar', false,
                              'alerta_admin', true, 'payment_id', p_mp_payment_id);
  END IF;
  SELECT telefono INTO v_tel FROM clientes WHERE id = v_ped.cliente_id;
  v_base := jsonb_build_object('pedido_id', v_ped.id, 'numero', v_ped.numero, 'telefono', v_tel,
                               'total', v_ped.total, 'moneda', trim(v_ped.moneda), 'payment_id', p_mp_payment_id,
                               'expira_en', v_ped.expira_en, 'mp_init_point', v_ped.mp_init_point);

  -- 2) registro del pago (UNIQUE mp_payment_id => no se duplica jamás)
  INSERT INTO pagos (pedido_id, mp_payment_id, estado, status_mp, status_detail, monto, moneda, metodo, raw)
  VALUES (v_ped.id, p_mp_payment_id, 'EN_PROCESO', p_status, p_status_detail, p_monto, upper(p_moneda), p_metodo, p_raw)
  ON CONFLICT (mp_payment_id) DO NOTHING;
  SELECT * INTO v_pago FROM pagos WHERE mp_payment_id = p_mp_payment_id FOR UPDATE;

  IF v_pago.pedido_id <> v_ped.id THEN
    RETURN v_base || jsonb_build_object('ok', false, 'codigo', 'PAGO_ASOCIADO_A_OTRO_PEDIDO',
                                        'notificar', false, 'alerta_admin', true);
  END IF;

  -- 3) idempotencia: mismo payment_id + mismo estado ya procesado => no hacer nada
  IF v_pago.procesado_en IS NOT NULL AND v_pago.estado = v_estado THEN
    RETURN v_base || jsonb_build_object('ok', true, 'codigo', 'YA_PROCESADO', 'notificar', false, 'alerta_admin', false);
  END IF;

  -- 4) pago aprobado: el monto y la moneda deben coincidir con el pedido
  IF v_estado = 'APROBADO' AND (p_monto IS DISTINCT FROM v_ped.total OR upper(COALESCE(p_moneda,'')) <> trim(v_ped.moneda)) THEN
    UPDATE pagos SET requiere_revision = true, revision_motivo = 'MONTO_O_MONEDA_NO_COINCIDE',
                     status_mp = p_status, status_detail = p_status_detail, procesado_en = now(),
                     estado = 'EN_PROCESO'
    WHERE id = v_pago.id AND NOT requiere_revision;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN v_base || jsonb_build_object('ok', false, 'codigo', 'MONTO_NO_COINCIDE', 'notificar', false,
                                        'alerta_admin', n > 0, 'monto_mp', p_monto);
  END IF;

  -- 5) transiciones según estado del pago
  IF v_estado = 'EN_PROCESO' THEN
    UPDATE pagos SET status_mp = p_status, status_detail = p_status_detail, procesado_en = now() WHERE id = v_pago.id;
    RETURN v_base || jsonb_build_object('ok', true, 'codigo', 'PAGO_EN_PROCESO', 'notificar', false, 'alerta_admin', false);

  ELSIF v_estado = 'RECHAZADO' THEN
    UPDATE pagos SET estado = 'RECHAZADO', status_mp = p_status, status_detail = p_status_detail, procesado_en = now()
    WHERE id = v_pago.id;
    IF v_ped.estado = 'PENDIENTE_PAGO' THEN
      PERFORM fn_cambiar_estado_pedido(v_ped.id, 'PAGO_RECHAZADO', 'PAGO_RECHAZADO_MP', 'mercadopago');
    END IF;
    -- se mantiene la reserva hasta su expiración; el cliente puede reintentar con el mismo link
    RETURN v_base || jsonb_build_object('ok', true, 'codigo', 'PAGO_RECHAZADO', 'mensaje', 'RECHAZADO',
      'notificar', v_ped.estado IN ('PENDIENTE_PAGO','PAGO_RECHAZADO') AND v_ped.expira_en > now(),
      'alerta_admin', false, 'detalle', p_status_detail);

  ELSIF v_estado = 'REEMBOLSADO' THEN
    UPDATE pagos SET estado = 'REEMBOLSADO', status_mp = p_status, status_detail = p_status_detail, procesado_en = now()
    WHERE id = v_pago.id;
    IF v_ped.estado IN ('PAGADO','PREPARANDO','LISTO_RETIRO','ENVIADO','ENTREGADO','RETIRADO','DEVUELTO') THEN
      PERFORM fn_cambiar_estado_pedido(v_ped.id, 'REEMBOLSADO', 'REEMBOLSO_MP', 'mercadopago');
      -- El stock NO se repone automáticamente: depende de si el producto volvió físicamente.
      RETURN v_base || jsonb_build_object('ok', true, 'codigo', 'PAGO_REEMBOLSADO', 'mensaje', 'REEMBOLSADO',
                                          'notificar', true, 'alerta_admin', true);
    END IF;
    RETURN v_base || jsonb_build_object('ok', true, 'codigo', 'REEMBOLSO_SIN_CAMBIO', 'notificar', false, 'alerta_admin', true);

  ELSE  -- APROBADO
    IF v_ped.estado IN ('PENDIENTE_PAGO','PAGO_RECHAZADO') THEN
      -- Consumir reservas ACTIVA (descuento definitivo). Si el webhook llega dos veces, la
      -- segunda ejecución ve el pago ya procesado (paso 3) o el pedido ya PAGADO.
      FOR v_it IN SELECT id, variante_id, cantidad FROM reservas_stock
                  WHERE pedido_id = v_ped.id AND estado = 'ACTIVA' ORDER BY variante_id FOR UPDATE
      LOOP
        UPDATE variantes SET stock_fisico = stock_fisico - v_it.cantidad,
                             stock_reservado = stock_reservado - v_it.cantidad
        WHERE id = v_it.variante_id;
        UPDATE reservas_stock SET estado = 'CONSUMIDA', consumida_en = now() WHERE id = v_it.id;
      END LOOP;
      UPDATE pagos SET estado = 'APROBADO', status_mp = p_status, status_detail = p_status_detail, procesado_en = now()
      WHERE id = v_pago.id;
      PERFORM fn_cambiar_estado_pedido(v_ped.id, 'PAGADO', 'PAGO_APROBADO_MP', 'mercadopago');
      RETURN v_base || jsonb_build_object('ok', true, 'codigo', 'PAGO_APROBADO', 'mensaje', 'PAGADO',
                                          'notificar', true, 'alerta_admin', false);

    ELSIF v_ped.estado = 'CANCELADO' THEN
      -- Pago tardío (carrera: el cliente pagó justo cuando expiró/canceló).
      -- Se intenta recuperar el pedido: descuenta stock solo si aún hay unidades libres.
      v_ok := true;
      BEGIN
        FOR v_it IN SELECT variante_id, cantidad FROM pedido_items WHERE pedido_id = v_ped.id ORDER BY variante_id LOOP
          UPDATE variantes SET stock_fisico = stock_fisico - v_it.cantidad
          WHERE id = v_it.variante_id AND stock_fisico - stock_reservado >= v_it.cantidad;
          IF NOT FOUND THEN RAISE EXCEPTION 'SIN_STOCK'; END IF;
          INSERT INTO reservas_stock (pedido_id, variante_id, cantidad, estado, expira_en, consumida_en)
          VALUES (v_ped.id, v_it.variante_id, v_it.cantidad, 'CONSUMIDA', now(), now())
          ON CONFLICT (pedido_id, variante_id) DO UPDATE
            SET estado = 'CONSUMIDA', consumida_en = now(), liberada_en = NULL, cantidad = EXCLUDED.cantidad;
        END LOOP;
      EXCEPTION WHEN raise_exception THEN
        IF SQLERRM = 'SIN_STOCK' THEN v_ok := false; ELSE RAISE; END IF;
      END;
      IF v_ok THEN
        UPDATE pagos SET estado = 'APROBADO', status_mp = p_status, status_detail = p_status_detail, procesado_en = now(),
                         requiere_revision = true, revision_motivo = 'PAGO_TARDIO_RECUPERADO'
        WHERE id = v_pago.id;
        PERFORM fn_cambiar_estado_pedido(v_ped.id, 'PAGADO', 'PAGO_TARDIO_RECUPERADO', 'mercadopago');
        RETURN v_base || jsonb_build_object('ok', true, 'codigo', 'PAGO_TARDIO_RECUPERADO', 'mensaje', 'PAGADO',
                                            'notificar', true, 'alerta_admin', true);
      END IF;
      UPDATE pagos SET estado = 'APROBADO', status_mp = p_status, status_detail = p_status_detail, procesado_en = now(),
                       requiere_revision = true, revision_motivo = 'PAGO_TARDIO_SIN_STOCK_REEMBOLSAR'
      WHERE id = v_pago.id;
      RETURN v_base || jsonb_build_object('ok', true, 'codigo', 'REQUIERE_REEMBOLSO', 'mensaje', 'REEMBOLSO_PENDIENTE',
                                          'notificar', true, 'alerta_admin', true);

    ELSE
      -- Pedido ya pagado/procesado y llega OTRO pago aprobado => doble cobro
      UPDATE pagos SET estado = 'APROBADO', status_mp = p_status, status_detail = p_status_detail, procesado_en = now(),
                       requiere_revision = true, revision_motivo = 'PAGO_DUPLICADO_REEMBOLSAR'
      WHERE id = v_pago.id;
      RETURN v_base || jsonb_build_object('ok', true, 'codigo', 'PAGO_DUPLICADO_REQUIERE_REEMBOLSO',
                                          'notificar', false, 'alerta_admin', true);
    END IF;
  END IF;
END $function$;

-- ----------------------------------------------------------------- Vista ----
CREATE OR REPLACE VIEW v_inconsistencias_stock AS
  SELECT v.id AS variante_id,
         v.sku,
         v.stock_reservado AS reservado_en_variante,
         COALESCE(r.suma, 0) AS suma_reservas_activas
  FROM variantes v
  LEFT JOIN (SELECT variante_id, sum(cantidad)::integer AS suma
             FROM reservas_stock WHERE estado = 'ACTIVA' GROUP BY variante_id) r ON r.variante_id = v.id
  WHERE v.stock_reservado <> COALESCE(r.suma, 0);
