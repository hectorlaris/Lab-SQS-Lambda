/**
 * Lambda Productor — Recibe peticiones y las envía a SQS
 *
 * Este es el punto de entrada HTTP. NO escribe en la DB directamente.
 * En su lugar, envía el mensaje a SQS que actúa como buffer resiliente.
 *
 * Beneficios:
 * - Responde 202 inmediatamente (baja latencia para el cliente)
 * - Si RDS está caído, no importa — el mensaje queda en SQS
 * - Soporta picos sin preocuparse por el connection pool de la DB
 */

const { SQSClient, SendMessageCommand } = require("@aws-sdk/client-sqs");

const sqsClient = new SQSClient({});
const QUEUE_URL = process.env.QUEUE_URL;

exports.handler = async (event) => {
  console.log("Request recibido:", JSON.stringify(event, null, 2));

  try {
    const body = JSON.parse(event.body);

    if (!body.product || !body.quantity || !body.customer) {
      return {
        statusCode: 400,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          error: "Campos requeridos: product, quantity, customer",
        }),
      };
    }

    const orderMessage = {
      orderId: `ORD-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
      product: body.product,
      quantity: body.quantity,
      customer: body.customer,
      timestamp: new Date().toISOString(),
    };

    // Enviar a SQS — esto es RESILIENTE:
    // SQS tiene 99.999999999% de durabilidad (11 nueves)
    const command = new SendMessageCommand({
      QueueUrl: QUEUE_URL,
      MessageBody: JSON.stringify(orderMessage),
    });

    const result = await sqsClient.send(command);

    console.log("Mensaje en SQS:", { messageId: result.MessageId, orderId: orderMessage.orderId });

    // 202 Accepted — el procesamiento es asíncrono
    // El cliente sabe que su orden FUE RECIBIDA aunque RDS esté caído
    return {
      statusCode: 202,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        message: "Orden recibida y encolada para procesamiento",
        orderId: orderMessage.orderId,
        sqsMessageId: result.MessageId,
        note: "La orden se procesará de forma asíncrona. Si la DB está caída, se reintentará automáticamente.",
      }),
    };
  } catch (error) {
    console.error("Error:", error);
    return {
      statusCode: 500,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ error: "Error interno" }),
    };
  }
};
