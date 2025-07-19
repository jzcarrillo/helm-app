const amqp = require('amqplib');
const express = require('express');
const axios = require('axios');

const QUEUE = 'submit_queue'; // match producer queue
const RABBITMQ_URL = 'amqp://myuser:mypass@rabbitmq.helm-app.svc.cluster.local:5672';
const BACKEND_URL = 'http://backend-service.helm-app.svc.cluster.local:3000/process';
const PORT = 4001;

let channel;

async function connectConsumer(retries = 10) {
  while (retries) {
    try {
      const connection = await amqp.connect(RABBITMQ_URL);
      connection.on('error', (err) => {
        console.error('[✗] RabbitMQ connection error:', err.message);
        process.exit(1);
      });

      connection.on('close', () => {
        console.warn('[!] RabbitMQ connection closed. Exiting...');
        process.exit(1);
      });

      channel = await connection.createChannel();
      await channel.assertQueue(QUEUE, { durable: true });

      console.log('[✓] Connected to RabbitMQ and queue asserted');

      // ✅ Start consuming and POST to backend
      channel.consume(QUEUE, async (msg) => {
        if (msg !== null) {
          const content = msg.content.toString();
          console.log(`[←] Consumed message: ${content}`);

          try {
            const payload = JSON.parse(content); // message must be valid JSON
            const response = await axios.post(BACKEND_URL, payload);
            console.log(`[✓] Forwarded to backend. Status: ${response.status}`);
            channel.ack(msg);
          } catch (err) {
            console.error('[✗] Failed to forward to backend:', err.message);
            // Optionally: channel.nack(msg); to requeue
          }
        }
      });

      return;
    } catch (err) {
      console.error(`[✗] RabbitMQ consumer connection failed: ${err.message}. Retrying in 3s...`);
      retries--;
      await new Promise((res) => setTimeout(res, 3000));
    }
  }

  console.error('[✗] Could not connect to RabbitMQ. Exiting.');
  process.exit(1);
}

connectConsumer();

// ✅ Health check endpoint
const app = express();

app.get('/health', (req, res) => {
  res.json({ status: 'ok', service: 'lambda-consumer' });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`[HTTP] Health endpoint running on port ${PORT}`);
});

app.get('/', (req, res) => {
  const statusHtml = '<span style="color:green;">✅ Lambda Consumer is up and running</span>';

  res.send(`
    <html>
      <head><title>Lambda Consumer</title></head>
      <body style="font-family:sans-serif; padding:20px;">
        <h2>${statusHtml}</h2>
      </body>
    </html>
  `);
});