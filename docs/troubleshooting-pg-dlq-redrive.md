# Troubleshooting: módulo `pg` faltante, DLQ y redrive

Este documento registra un incidente real del lab y cómo se resolvió de punta a
punta. Es, en la práctica, la demostración central del valor de SQS: un fallo del
consumidor que en una arquitectura directa habría perdido 2000 órdenes, aquí se
recuperó sin pérdidas.

---

## 1. Síntoma

Tras una prueba de carga con k6 (1000 requests), las métricas de k6 mostraban
respuestas `2xx` (las órdenes se "aceptaban"), pero al revisar las colas:

- **Cola principal (`orders-lab-sls-orders-queue`)**: 0 mensajes.
- **Dead Letter Queue (`orders-lab-sls-orders-dlq`)**: **2000 mensajes**.

Es decir: nada se estaba guardando en RDS. Todos los mensajes terminaban en la DLQ.

> Lección de método: un `2xx` del endpoint serverless significa **"encolado"**, no
> **"guardado en RDS"**. El productor responde en cuanto SQS acepta el mensaje; el
> procesamiento real ocurre después, de forma asíncrona, en el consumidor.

---

## 2. Diagnóstico

El flujo serverless es:

```
API Gateway → Lambda producer → SQS → Lambda consumer → RDS
                                         ↓ (tras 3 fallos)
                                        DLQ
```

Si los mensajes llegan a la DLQ, el eslabón que falla es el **consumidor**. Al
inspeccionar el paquete desplegado (`dist/consumer.zip`) se encontró la causa:

```
consumer.zip
├── index.js
└── package.json        ← faltaba node_modules/
```

El zip **no incluía `node_modules`**, pero el código hace:

```javascript
const { Pool } = require("pg");   // cliente PostgreSQL para Node.js
```

Sin el módulo `pg` en el paquete, la Lambda falla al arrancar con
`Cannot find module 'pg'`, nunca llega a conectar con RDS, el mensaje se marca
como fallido, SQS reintenta 3 veces (`maxReceiveCount = 3`) y finalmente lo envía
a la DLQ.

### ¿Por qué el producer sí funcionaba?

El productor usa `@aws-sdk/client-sqs`, que **viene preinstalado** en el runtime
de Lambda para Node.js. El cliente `pg`, en cambio, es una dependencia externa que
**debe empaquetarse** junto al código.

### `pg` no es PostgreSQL

- **PostgreSQL**: la base de datos (el `aws_db_instance.postgres` en RDS).
- **`pg`** ([node-postgres](https://www.npmjs.com/package/pg)): el driver/cliente
  de Node.js para hablar con esa base de datos. Sin el driver, el código no puede
  comunicarse con la DB aunque la DB exista.

---

## 3. Solución

### Paso 1 — Incluir `pg` en el paquete del consumidor

Instalar la dependencia dentro de la carpeta del consumidor para que
`archive_file` la empaquete:

```powershell
cd serverless/src/consumer
npm install --omit=dev
```

Esto crea `node_modules/pg` (y sus dependencias) en la carpeta. `archive_file`
empaqueta todo el `source_dir`, así que el zip pasa de ~1 KB a ~150 KB.

> Nota: `node_modules/` está en `.gitignore` (correcto para git), pero eso **no**
> afecta a `archive_file` — Terraform lo incluye igual en el zip.

### Paso 2 — Redesplegar el consumidor

```powershell
$env:TF_VAR_db_password = "<password-rds>"
cd serverless/terraform
terraform apply "-target=aws_lambda_function.consumer" "-var=aws_profile=<perfil>" -auto-approve
```

El `source_code_hash` cambia (el zip es distinto), así que Terraform detecta el
cambio y actualiza la función. Confirmación esperada:

```
~ source_code_hash = "CGAImHZ6..." -> "LPbT/DesI..."
Plan: 0 to add, 1 to change, 0 to destroy.
```

### Paso 3 — Verificar con una orden de prueba

```powershell
curl -X POST "https://<api-url>/orders" -H "Content-Type: application/json" `
  -d '{\"product\":\"test-fix\",\"quantity\":1,\"customer\":\"test@example.com\"}'

aws logs tail /aws/lambda/orders-lab-sls-consumer --since 2m --profile <perfil> --region us-east-1
```

En los logs ya debe aparecer la escritura exitosa (y no `Cannot find module`):

```
INFO  Procesando batch de 1 mensaje(s) desde SQS
INFO  Escribiendo en RDS: { orderId: 'ORD-...', attempt: '1' }
INFO  ✓ Orden ORD-... guardada en RDS
INFO  Todos los 1 mensajes procesados exitosamente
```

### Paso 4 — Redrive: recuperar los 2000 de la DLQ

Con el consumidor ya arreglado, se devuelven los mensajes de la DLQ a la cola
principal. SQS tiene una operación nativa para esto (*message move task*):

```powershell
$dlqArn = "arn:aws:sqs:us-east-1:<account-id>:orders-lab-sls-orders-dlq"

# Sin --destination-arn, los mensajes vuelven a su cola de ORIGEN (la principal)
aws sqs start-message-move-task --source-arn $dlqArn --profile <perfil> --region us-east-1

# Seguir el progreso
aws sqs list-message-move-tasks --source-arn $dlqArn --profile <perfil> --region us-east-1
```

Resultado:

```json
{
  "Results": [{
    "Status": "COMPLETED",
    "ApproximateNumberOfMessagesMoved": 2000,
    "ApproximateNumberOfMessagesToMove": 2000
  }]
}
```

> El `redrive_allow_policy` de la DLQ (definido en `sqs.tf`) debe permitir el
> retorno a la cola de origen. En este lab ya está configurado.

A medida que los mensajes regresan a la cola principal, el *event source mapping*
dispara al consumidor en lotes de 5 (`consumer_batch_size`) y los procesa.

### Paso 5 — Confirmar persistencia en RDS

Verificación definitiva: un `COUNT(*)` real contra la tabla `orders`, vía la
Lambda checker (ver sección siguiente):

```powershell
.\check-db.ps1
```

```
TOTAL de ordenes en RDS: 2001        # 2000 de la DLQ + 1 orden de prueba
Desglose por status:
  processed      2001
```

---

## 4. La Lambda checker (verificar RDS en subnets privadas)

RDS tiene `publicly_accessible = false` y vive en subnets privadas, así que **no
se puede consultar desde el PC** con un cliente PostgreSQL: no hay ruta de red.

La solución es una Lambda de solo lectura (`serverless/src/checker/`, definida en
`checker.tf`) que vive en las mismas subnets que el consumidor y ejecuta los
SELECT. Se invoca manualmente:

```powershell
.\check-db.ps1
```

### Sub-incidente: `-target` omite dependencias → ENI sin permisos

Al desplegar la checker con `terraform apply -target=aws_lambda_function.checker`,
la creación se quedó colgada ~4 minutos y falló con:

```
InvalidParameterValueException: The provided execution role does not have
permissions to call CreateNetworkInterface on EC2
```

**Causa raíz** (no era propagación de IAM, como parecía al principio): el flag
`-target` creó la función pero **omitió** el recurso
`aws_iam_role_policy.checker_policy`, porque no es una dependencia que Terraform
arrastre automáticamente con el target. El rol quedó sin política adjunta, por eso
Lambda no podía crear la ENI (interfaz de red en la VPC).

```powershell
# Evidencia: el rol no tenía ninguna política
aws iam list-role-policies --role-name orders-lab-sls-checker-role
# → { "PolicyNames": [] }
```

**Solución**: hacer un `apply` **completo** (sin `-target`), que crea la política y
la función respetando el orden de dependencias:

```powershell
terraform apply "-var=aws_profile=<perfil>" -auto-approve
```

Con la política creada primero, la función se creó en **14 segundos** (no 4
minutos):

```
aws_iam_role_policy.checker_policy: Creation complete after 1s
aws_lambda_function.checker: Creation complete after 14s
```

> Lección: `-target` es para situaciones excepcionales. Omite recursos
> dependientes que no sean dependencias directas del objeto apuntado y puede dejar
> la infraestructura en un estado incoherente. Para un despliegue normal, usar
> `apply` completo.

---

## 5. Conclusión del lab

| Fase | Acción | Evidencia |
|---|---|---|
| Diagnóstico | Consumidor fallaba por falta de `pg` | 2000 órdenes en DLQ |
| Fix + deploy | `npm install pg` + redeploy | `CodeSize` ~150 KB, hash nuevo |
| Verificación | 1 orden de prueba | `✓ guardada en RDS` |
| Redrive | `start-message-move-task` | 2000/2000 movidos, `COMPLETED` |
| Confirmación | `check-db.ps1` → `COUNT(*)` | **2001 filas `processed`** |

**La lección central, comprobada en vivo:** cuando el consumidor falló, SQS retuvo
las 2000 órdenes en la DLQ. **Ninguna se perdió.** Tras corregir el código, el
redrive las recuperó todas hacia RDS.

En la arquitectura `server-full` (Express → RDS directo, sin cola), esas mismas
2000 órdenes habrían sido errores `500` irrecuperables en el momento del fallo.

---

## Archivos relacionados

- `docs/k6-explication.md` — conceptos y uso de k6 para las pruebas de carga.
- `load-test.k6.js` — prueba de carga que generó las 1000 órdenes iniciales.
- `serverless/src/consumer/index.js` — consumidor (lee de SQS, escribe en RDS).
- `serverless/src/checker/index.js` — Lambda de verificación (solo lectura).
- `check-db.ps1` — invoca la checker y muestra el conteo en RDS.
