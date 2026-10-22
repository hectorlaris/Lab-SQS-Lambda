
----

###  1. El test se escribe en JavaScript. 
    No configuras k6 con botones, le das un archivo .js (ya tienes uno: load-test.k6.js). 
    k6 ejecuta la función default de ese archivo muchas veces en paralelo. 
    Cada ejecución de esa función es una "iteración" = normalmente un request.

### 2. VUs (Virtual Users = usuarios virtuales). 
    Es el concepto central. Un VU es un "usuario falso" que ejecuta tu función una y otra vez.
    Si pones 50 VUs, tienes 50 usuarios golpeando el endpoint al mismo tiempo. Eso es la concurrencia. 
    Más VUs = más presión simultánea.

# 3. Métricas. Al terminar, k6 te da un resumen. Las que importan:

| Métrica | Qué significa | Por qué te importa |
|---|---|---|
| `http_req_duration` | Cuánto tardó cada request (latencia) | Lo clave. Se mira el p95: “el 95% de los requests fueron más rápidos que esto” |
| `http_req_failed` | % de requests que fallaron | En tu lab = órdenes perdidas |
| `http_reqs` | Total de requests y requests/segundo | El throughput, cuánto aguanta |
| `iterations` | Cuántas veces corrió tu función | En tu test, = total de órdenes enviadas |
| `vus` | Usuarios virtuales activos | La concurrencia real en cada momento |

----
Sobre percentiles, porque confunden al principio: el p95 es más honesto que el promedio. Si 99 requests tardan 50ms y uno tarda 10 segundos, el promedio miente (parece bueno), pero el p95/p99 te delata ese pico. Por eso en carga siempre se mira p95 y p99, no el promedio.

# desde la raíz del proyecto

k6 version

$env:TARGET_URL="https://yq20559n8e.execute-api.us-east-1.amazonaws.com/orders"

k6 run load-test.k6.js
k6 run hello-k6.js

 Para quedarte solo con el resumen, puedes guardarlo a archivo con

 k6 run --summary-export=resultado.json load-test.k6.js