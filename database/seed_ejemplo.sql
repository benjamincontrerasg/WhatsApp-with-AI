-- Datos de ejemplo para probar el flujo (opcional). Cámbialos por tu catálogo real.
INSERT INTO tiendas (nombre, moneda) VALUES ('Mi Tienda', 'CLP');

WITH t AS (SELECT id FROM tiendas LIMIT 1),
p AS (
  INSERT INTO productos (tienda_id, nombre, descripcion, categoria)
  SELECT t.id, x.nombre, x.descripcion, x.categoria FROM t,
  (VALUES ('Camiseta básica',  'Algodón 100%',  'camisetas'),
          ('Polerón con capucha','Polar suave', 'polerones')) AS x(nombre, descripcion, categoria)
  RETURNING id, nombre
)
INSERT INTO variantes (producto_id, sku, talla, color, precio, stock_fisico)
SELECT p.id, v.sku, v.talla, v.color, v.precio, v.stock FROM p
JOIN (VALUES
  ('Camiseta básica',    'CAM-NEG-M', 'M', 'Negro', 9990,  10),
  ('Camiseta básica',    'CAM-NEG-L', 'L', 'Negro', 9990,  5),
  ('Camiseta básica',    'CAM-BLA-M', 'M', 'Blanco', 9990, 8),
  ('Polerón con capucha','POL-GRI-M', 'M', 'Gris',  24990, 4),
  ('Polerón con capucha','POL-GRI-L', 'L', 'Gris',  24990, 2)
) AS v(prod, sku, talla, color, precio, stock) ON v.prod = p.nombre;
