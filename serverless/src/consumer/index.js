/**
 * Lambda Consumidor — Lee de SQS y escribe en RDS
 *
 * AWS invoca esta Lambda automáticamente cuando hay mensajes en SQS.
 * 
 * Resiliencia demostrada:
 * 1. Si RDS está caído → esta Lambda falla → SQS REINTENTA el mensaje
 * 2. Si falla 3 veces → mensaje va a DLQ (no se pierde, se investiga)
 * 3. Partial batch failure: solo se reintentan los mensajes que fallaron
 *
 * Comparación con server-full:
 * - Server-full: falla la escritura → error 500 → orden PERDIDA
 * - Serverless: falla la escritura → mensaje vuelve a SQS → reintento automático
 */

const { Pool } = require("pg");

// Pool de conexiones a RDS
// Se reutiliza entre invocaciones de Lambda (warm start)
const pool = new Pool({
  host: process.env.DB_HOST,
  port: parseInt(process.env.DB_PORT || "5432", 10),
  database: process.env.DB_NAME || "orders",
  user: process.env.DB_USER || "labuser",
  password: process.env.DB_PASSWORD,
  max: 2, // Lambda: pocas conexiones por instancia (escala horizontalmente)
  idleTimeoutMillis: 120000,
  connectionTimeoutMillis: 5000,
  ssl: { rejectUnauthorized: false },
});

let tableInitialized = false;

async function ensureTable() {
  if (tableInitialized) return;
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
  tableInitialized = true;
}

exports.handler = async (event) => {
  console.log(`Procesando batch de ${event.Records.length} mensaje(s) desde SQS`);

  await ensureTable();

  const failures = [];

  for (const record of event.Records) {
    try {
      const order = JSON.parse(record.body);

      console.log("Escribiendo en RDS:", {
        orderId: order.orderId,
        attempt: record.attributes.ApproximateReceiveCount,
      });

      // Simular fallo para prueba de DLQ: si el producto empieza con "dlq-force"
      // el consumer SIEMPRE falla → tras 3 intentos el mensaje va a DLQ
      if (order.product && order.product.startsWith("dlq-force")) {
        throw new Error(`Fallo simulado para DLQ test: ${order.orderId}`);
      }

      await pool.query(
        `INSERT INTO orders (order_id, product, quantity, customer, status, processed_at)
         VALUES ($1, $2, $3, $4, 'processed', NOW())
         ON CONFLICT (order_id) DO NOTHING`,
        [order.orderId, order.product, order.quantity, order.customer]
      );

      console.log(`✓ Orden ${order.orderId} guardada en RDS`);
    } catch (error) {
      console.error(`✗ Error procesando mensaje ${record.messageId}:`, error.message);
      console.error(`  → Intento #${record.attributes.ApproximateReceiveCount}. SQS reintentará.`);

      // Reportar como fallo parcial — SQS reintentará SOLO este mensaje
      failures.push({ itemIdentifier: record.messageId });
    }
  }

  if (failures.length > 0) {
    console.log(`${failures.length}/${event.Records.length} mensajes fallaron — serán reintentados por SQS`);
  } else {
    console.log(`Todos los ${event.Records.length} mensajes procesados exitosamente`);
  }

  return { batchItemFailures: failures };
};
