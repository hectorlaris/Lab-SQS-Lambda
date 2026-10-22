// Prueba de carga con k6 para el lab SQS + Lambda.
//
// Instalar k6 (una vez):   winget install k6   (o: choco install k6)
//
// Ejecutar contra el endpoint serverless:
//   $env:TARGET_URL="https://yq20559n8e.execute-api.us-east-1.amazonaws.com/orders"
//   k6 run load-test.k6.js
//
// Ejecutar contra el server-full (EC2):
//   $env:TARGET_URL="http://<EC2_IP>:3000/orders"
//   k6 run load-test.k6.js
//
// Parametrizable por variables de entorno:
//   TARGET_URL  - endpoint POST /orders (obligatorio)
//   VUS         - usuarios virtuales concurrentes (default 50)
//   TOTAL       - total de iteraciones/requests (default 1000)

import http from "k6/http";
import { check } from "k6";
import { Counter, Trend } from "k6/metrics";

const TARGET_URL = __ENV.TARGET_URL;
const VUS = parseInt(__ENV.VUS || "50", 10);
const TOTAL = parseInt(__ENV.TOTAL || "1000", 10);

if (!TARGET_URL) {
  throw new Error("Define TARGET_URL. Ej: $env:TARGET_URL='https://.../orders'");
}

// Metricas personalizadas
const ordersLost = new Counter("orders_lost"); // respuestas no-2xx = ordenes perdidas
const ordersOk = new Counter("orders_accepted");
const serverLatency = new Trend("order_latency_ms", true);

export const options = {
  scenarios: {
    burst: {
      // Lanza TOTAL iteraciones repartidas entre VUS usuarios concurrentes.
      executor: "shared-iterations",
      vus: VUS,
      iterations: TOTAL,
      maxDuration: "5m",
    },
  },
  thresholds: {
    // El lab espera que serverless cumpla esto y server-full lo rompa.
    http_req_failed: ["rate<0.01"], // < 1% de errores
    http_req_duration: ["p(95)<2000"], // p95 bajo 2s
  },
};

export default function () {
  const payload = JSON.stringify({
    product: "laptop",
    quantity: 1,
    customer: `k6-${__VU}-${__ITER}@example.com`,
  });

  const params = {
    headers: { "Content-Type": "application/json" },
    timeout: "15s",
  };

  const res = http.post(TARGET_URL, payload, params);
  serverLatency.add(res.timings.duration);

  const accepted = check(res, {
    "status 2xx": (r) => r.status >= 200 && r.status < 300,
  });

  if (accepted) {
    ordersOk.add(1);
  } else {
    // En server-full esto sube con el pico (pool de 10 conexiones agotado).
    ordersLost.add(1);
  }
}

export function handleSummary(data) {
  const lost = data.metrics.orders_lost ? data.metrics.orders_lost.values.count : 0;
  const ok = data.metrics.orders_accepted ? data.metrics.orders_accepted.values.count : 0;
  const line = "=".repeat(60);
  const text =
    `\n${line}\n  RESUMEN DE CARGA\n${line}\n` +
    `  Ordenes aceptadas (2xx): ${ok}\n` +
    `  Ordenes perdidas (no-2xx): ${lost}\n` +
    `  (con SQS deberia ser 0; server-full perdera ordenes)\n${line}\n`;
  return {
    stdout: text,
  };
}
