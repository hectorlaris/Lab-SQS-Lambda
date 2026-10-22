/**
 * Lambda Checker — Consulta la tabla `orders` en RDS y devuelve conteos.
 *
 * Existe solo para VERIFICAR el lab: RDS esta en subnets privadas, asi que
 * no se puede consultar desde fuera de la VPC. Esta Lambda vive en las mismas
 * subnets que el consumer y ejecuta SELECTs de solo lectura.
 *
 * Se invoca manualmente (no tiene trigger). El script check-db.ps1 la llama.
 *
 * Respuesta (JSON):
 *   {
 *     "total": 1000,
 *     "byStatus": { "processed": 1000 },
 *     "lastOrders": [ { orderId, product, quantity, customer, created_at }, ... ],
 *     "oldest": "2026-...", "newest": "2026-..."
 *   }
 */

const { Pool } = require("pg");

// Mismo patron de pool que el consumer. Reutilizado entre invocaciones (warm start).
const pool = new Pool({
  host: process.env.DB_HOST,
  port: parseInt(process.env.DB_PORT || "5432", 10),
  database: process.env.DB_NAME || "orders",
  user: process.env.DB_USER || "labuser",
  password: process.env.DB_PASSWORD,
  max: 1,
  idleTimeoutMillis: 120000,
  connectionTimeoutMillis: 5000,
  ssl: { rejectUnauthorized: false },
});

exports.handler = async () => {
  try {
    // 1) Total de filas
    const totalRes = await pool.query("SELECT COUNT(*)::int AS total FROM orders");
    const total = totalRes.rows[0].total;

    // 2) Desglose por status
    const statusRes = await pool.query(
      "SELECT status, COUNT(*)::int AS count FROM orders GROUP BY status ORDER BY count DESC"
    );
    const byStatus = {};
    for (const row of statusRes.rows) {
      byStatus[row.status] = row.count;
    }

    // 3) Rango temporal (primera y ultima orden)
    const rangeRes = await pool.query(
      "SELECT MIN(created_at) AS oldest, MAX(created_at) AS newest FROM orders"
    );

    // 4) Ultimas 5 ordenes insertadas
    const lastRes = await pool.query(
      `SELECT order_id, product, quantity, customer, status, created_at
       FROM orders
       ORDER BY created_at DESC
       LIMIT 5`
    );

    return {
      ok: true,
      total,
      byStatus,
      oldest: rangeRes.rows[0].oldest,
      newest: rangeRes.rows[0].newest,
      lastOrders: lastRes.rows,
    };
  } catch (error) {
    // Devolvemos el error como dato (no lanzamos) para que el script lo muestre claro.
    return {
      ok: false,
      error: error.message,
    };
  }
};
