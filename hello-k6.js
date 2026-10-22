// =============================================================================
// hello-k6.js  —  Tu primer test con k6 (archivo de practica)
// =============================================================================
//
// Objetivo: aprender las piezas de k6 contra un servidor publico de pruebas
// (https://test.k6.io, hospedado por Grafana justo para esto). NO toca tu lab.
//
// Como ejecutarlo (desde la carpeta del proyecto, en una terminal NUEVA):
//
//   k6 run hello-k6.js
//
// Si "k6" no se reconoce aun (no reiniciaste la terminal), usa la ruta completa:
//
//   & "D:\tools\k6\k6.exe" run hello-k6.js
//
// =============================================================================

// ---- 1. IMPORTS ----
// k6 trae modulos propios (no es Node.js). Se importan con rutas tipo "k6/...".
import http from "k6/http";            // para hacer peticiones HTTP (get, post, ...)
import { check, sleep } from "k6";     // check = validar respuestas; sleep = pausar

// ---- 2. OPTIONS ----
// Aqui defines COMO se ejecuta la prueba: cuantos usuarios y por cuanto tiempo.
export const options = {
  // "stages" dibuja una curva de carga a lo largo del tiempo (mas realista
  // que un numero fijo de VUs). Cada stage dice: "en este tiempo, llega a
  // este numero de usuarios virtuales".
  stages: [
    { duration: "10s", target: 5 },   // 1) sube de 0 a 5 VUs en 10s (rampa de subida)
    { duration: "20s", target: 5 },   // 2) mantiene 5 VUs durante 20s (carga sostenida)
    { duration: "5s", target: 0 },    // 3) baja de 5 a 0 VUs en 5s (rampa de bajada)
  ],

  // "thresholds" = criterios de aprobado/reprobado. Si no se cumplen, k6
  // termina con codigo de error (util en CI/CD). Veras un ✓ o ✗ por cada uno.
  thresholds: {
    http_req_duration: ["p(95)<800"],  // el 95% de requests debe responder en < 800 ms
    http_req_failed: ["rate<0.01"],    // menos del 1% de requests puede fallar
  },
};

// ---- 3. FUNCION DEFAULT ----
// Esto es lo que ejecuta CADA usuario virtual, una y otra vez, mientras dure
// la prueba. Cada vuelta completa es una "iteration".
export default function () {
  // Hacemos un GET a la pagina de pruebas publica de k6.
  const res = http.get("https://test.k6.io");

  // "check" valida la respuesta. No detiene la prueba si falla: solo cuenta
  // cuantas veces se cumplio cada condicion (lo veras en el resumen final).
  check(res, {
    "status es 200": (r) => r.status === 200,
    "cargo en < 800ms": (r) => r.timings.duration < 800,
    "el body no esta vacio": (r) => r.body && r.body.length > 0,
  });

  // Pausa de 1 segundo: simula el "tiempo de lectura" de un usuario real
  // antes de hacer su siguiente accion. Sin sleep, cada VU martillaria el
  // servidor sin pausa (a veces se quiere, a veces no).
  sleep(1);
}

// =============================================================================
// COMO LEER EL RESUMEN AL TERMINAR
// =============================================================================
//
//   http_req_duration ... avg=120ms p(95)=450ms   -> latencia; fijate SIEMPRE en p(95)
//   http_req_failed ..... 0.00%                    -> % de requests fallidos
//   http_reqs ........... 150    5.0/s             -> total de requests y throughput (req/s)
//   iterations .......... 150                      -> cuantas veces corrio tu funcion
//   vus ................. 5                         -> usuarios virtuales (concurrencia)
//   checks .............. 100.00%                   -> % de validaciones "check" que pasaron
//
// Junto a cada threshold veras:
//   ✓  (verde) = se cumplio el criterio
//   ✗  (rojo)  = NO se cumplio (la prueba se marca como fallida)
//
// =============================================================================
