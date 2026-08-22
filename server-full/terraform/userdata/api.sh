#!/bin/bash
# =============================================================================
# User Data — EC2 API Server (Express → RDS directo)
# =============================================================================
set -e

dnf update -y
dnf install -y nodejs npm

mkdir -p /opt/app
cd /opt/app

cat > package.json << 'EOF'
{
  "name": "server-full-orders-api",
  "version": "1.0.0",
  "dependencies": {
    "express": "4.19.2",
    "pg": "8.12.0"
  }
}
EOF

npm install --production

cat > server.js << 'SERVEREOF'
const express = require("express");
const { Pool } = require("pg");

const PORT = 3000;

const pool = new Pool({
  host: process.env.DB_HOST,
  port: parseInt(process.env.DB_PORT, 10),
  database: process.env.DB_NAME,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  max: 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
  ssl: { rejectUnauthorized: false },
});

const app = express();
app.use(express.json());

async function initDB() {
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
  console.log("Tabla 'orders' lista");
}

app.get("/health", async (req, res) => {
  try {
    await pool.query("SELECT 1");
    res.json({ status: "healthy", db: "connected" });
  } catch (error) {
    res.status(503).json({ status: "unhealthy", error: error.message });
  }
});

app.post("/orders", async (req, res) => {
  const startTime = Date.now();
  try {
    const { product, quantity, customer } = req.body;
    if (!product || !quantity || !customer) {
      return res.status(400).json({ error: "Campos requeridos: product, quantity, customer" });
    }
    const orderId = `ORD-$${Date.now()}-$${Math.random().toString(36).substr(2, 9)}`;
    const result = await pool.query(
      `INSERT INTO orders (order_id, product, quantity, customer, status, processed_at)
       VALUES ($1, $2, $3, $4, 'processed', NOW()) RETURNING id, order_id, created_at`,
      [orderId, product, quantity, customer]
    );
    const elapsed = Date.now() - startTime;
    console.log(`Orden $${orderId} guardada en $${elapsed}ms`);
    res.status(201).json({
      message: "Orden procesada y guardada",
      orderId: result.rows[0].order_id,
      processingTime: `$${elapsed}ms`,
    });
  } catch (error) {
    const elapsed = Date.now() - startTime;
    console.error(`Error tras $${elapsed}ms:`, error.message);
    res.status(500).json({
      error: "Error escribiendo en base de datos",
      detail: error.message,
      note: "Esta orden se PERDIO. Con SQS quedaria en cola para reintento.",
    });
  }
});

app.get("/orders", async (req, res) => {
  try {
    const result = await pool.query("SELECT * FROM orders ORDER BY created_at DESC LIMIT 50");
    res.json({ count: result.rows.length, orders: result.rows });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.get("/stats", async (req, res) => {
  try {
    const result = await pool.query(`
      SELECT COUNT(*) as total_orders,
        MIN(created_at) as first_order,
        MAX(created_at) as last_order
      FROM orders
    `);
    res.json({
      ...result.rows[0],
      pool: { total: pool.totalCount, idle: pool.idleCount, waiting: pool.waitingCount },
    });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

initDB().then(() => {
  app.listen(PORT, () => {
    console.log(`API Server en puerto $${PORT} — escritura directa a RDS`);
  });
});

process.on("SIGTERM", async () => { await pool.end(); process.exit(0); });
SERVEREOF

cat > /etc/systemd/system/orders-api.service << EOF
[Unit]
Description=Orders API Server (direct to RDS)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/app
Environment=DB_HOST=${db_host}
Environment=DB_PORT=${db_port}
Environment=DB_NAME=${db_name}
Environment=DB_USER=${db_user}
Environment=DB_PASSWORD=${db_password}
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable orders-api
systemctl start orders-api
