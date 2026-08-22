/**
 * Server-full: Express → RDS directa (sin cola)
 *
 * Este servidor escribe directamente a PostgreSQL sin ningún buffer intermedio.
 * 
 * Problemas que vas a observar en las pruebas:
 * 1. Si RDS se cae → error 500, la orden se PIERDE
 * 2. Si llegan muchos requests simultáneos → pool se agota → requests fallan
 * 3. Si este proceso se reinicia → requests en vuelo se pierden
 *
 * Compara esto con la versión serverless donde SQS absorbe estos problemas.
 */

const express = require("express");
const { Pool } = require("pg");

const PORT = process.env.PORT || 3000;

// Connection pool a PostgreSQL (RDS)
// maxPoolSize limita las conexiones simultáneas — punto de saturación
const pool = new Pool({
  host: process.env.DB_HOST,
  port: process.env.DB_PORT || 5432,
  database: process.env.DB_NAME || "orders",
  user: process.env.DB_USER || "labuser",
  password: process.env.DB_PASSWORD,
  max: 10, // Máximo 10 conexiones simultáneas (punto clave para la prueba de carga)
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000, // Si no puede conectar en 5s → error
});

const app = express();
app.use(express.json());

// Inicializar tabla al arrancar
async function initDB() {
  try {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS orders (
        id SERIAL PRIMARY KEY,
        order_id VARCHAR(50) UNIQUE NOT NULL,
        product VARCHAR(100) NOT NULL,
        quantity INTEGER NOT NULL,
        customer VARCHAR(200) NOT NULL,
        status VARCHAR(20) DEFAULT 'received',
        created_at TIMESTAMP DEFAULT NOW(),
        processed_at TIMESTAMP
      )
    `);
    console.log("Tabla 'orders' inicializada");
  } catch (error) {
    console.error("Error inicializando DB:", error.message);
    process.exit(1);
  }
}

// Health check
app.get("/health", async (req, res) => {
  try {
    await pool.query("SELECT 1");
    res.json({ status: "healthy", db: "connected" });
  } catch (error) {
    res.status(503).json({ status: "unhealthy", db: "disconnected", error: error.message });
  }
});

// POST /orders — Escritura DIRECTA a RDS (sin cola)
app.post("/orders", async (req, res) => {
  const startTime = Date.now();

  try {
    const { product, quantity, customer } = req.body;

    if (!product || !quantity || !customer) {
      return res.status(400).json({
        error: "Campos requeridos: product, quantity, customer",
      });
    }

    const orderId = `ORD-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;

    // Escritura directa — si RDS está caído, esto FALLA y se pierde la orden
    const result = await pool.query(
      `INSERT INTO orders (order_id, product, quantity, customer, status, processed_at)
       VALUES ($1, $2, $3, $4, 'processed', NOW())
       RETURNING id, order_id, created_at`,
      [orderId, product, quantity, customer]
    );

    const elapsed = Date.now() - startTime;
    console.log(`Orden ${orderId} guardada en ${elapsed}ms`);

    // 201 Created — procesamiento síncrono completado
    res.status(201).json({
      message: "Orden procesada y guardada",
      orderId: result.rows[0].order_id,
      dbId: result.rows[0].id,
      processingTime: `${elapsed}ms`,
    });
  } catch (error) {
    const elapsed = Date.now() - startTime;
    console.error(`Error tras ${elapsed}ms:`, error.message);

    // Aquí es donde ves la diferencia vs SQS:
    // - Con SQS: el mensaje queda en la cola, se reintenta después
    // - Sin SQS: devolvemos error 500, la orden SE PIERDE
    res.status(500).json({
      error: "Error escribiendo en base de datos",
      detail: error.message,
      note: "⚠️ Esta orden se PERDIÓ. Con SQS, quedaría en cola para reintento.",
    });
  }
});

// GET /orders — Ver órdenes guardadas
app.get("/orders", async (req, res) => {
  try {
    const result = await pool.query(
      "SELECT * FROM orders ORDER BY created_at DESC LIMIT 50"
    );
    res.json({ count: result.rows.length, orders: result.rows });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// GET /stats — Estadísticas
app.get("/stats", async (req, res) => {
  try {
    const result = await pool.query(`
      SELECT 
        COUNT(*) as total_orders,
        COUNT(CASE WHEN status = 'processed' THEN 1 END) as processed,
        MIN(created_at) as first_order,
        MAX(created_at) as last_order
      FROM orders
    `);
    res.json({
      ...result.rows[0],
      pool: {
        total: pool.totalCount,
        idle: pool.idleCount,
        waiting: pool.waitingCount,
      },
    });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Arrancar servidor
initDB().then(() => {
  app.listen(PORT, () => {
    console.log(`Server-full API en puerto ${PORT}`);
    console.log(`DB: ${process.env.DB_HOST}:${process.env.DB_PORT || 5432}`);
    console.log(`Pool máximo: 10 conexiones`);
    console.log("");
    console.log("⚠️  Sin cola intermedia — escritura directa a RDS");
    console.log("⚠️  Si RDS cae, las órdenes se PIERDEN");
  });
});

// Graceful shutdown
process.on("SIGTERM", async () => {
  console.log("Cerrando conexiones...");
  await pool.end();
  process.exit(0);
});
