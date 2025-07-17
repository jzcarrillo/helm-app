const express = require('express');
const rateLimit = require('express-rate-limit');
const client = require('prom-client');
const axios = require('axios');
const os = require('os');

const app = express();
const PORT = 8081;
const FRONTEND = 'http://localhost:80';

// === Metrics ===
const register = new client.Registry();
client.collectDefaultMetrics({ register });

const totalRequests = new client.Counter({
  name: 'api_gateway_requests_total',
  help: 'Total number of requests to API Gateway',
  labelNames: ['route', 'method'],
});
const throttledRequests = new client.Counter({
  name: 'api_gateway_429_total',
  help: 'Total number of 429 responses',
  labelNames: ['route'],
});
register.registerMetric(totalRequests);
register.registerMetric(throttledRequests);

// === Middleware ===
app.use(express.json());
app.use((req, res, next) => {
  res.header('Access-Control-Allow-Origin', FRONTEND);
  res.header('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
  res.header('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});
app.use((req, res, next) => {
  totalRequests.inc({ route: req.path, method: req.method });
  next();
});

// === Health and metrics
app.get('/', (req, res) => res.send('✅ API Gateway UP'));
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

// === Rate limiter
const submitLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 20,
  handler: (req, res) => {
    throttledRequests.inc({ route: '/submit' });
    res.status(429).json({ message: 'Too many requests to /submit' });
  },
});

// === POST /submit forwarding to lambda-producer-service
app.post('/submit', submitLimiter, async (req, res) => {
  console.log(`[LOG] Incoming POST request to /submit from ${os.hostname()}`);
  try {
    const response = await axios.post(
      'http://lambda-producer-service:4000/submit', // ✅ fixed endpoint
      req.body,
      {
        headers: {
          'Content-Type': 'application/json',
        },
        timeout: 5000,
      }
    );

    console.log(`[✅ SUCCESS] Forwarded to lambda-producer-service: ${response.status}`);
    res.status(response.status).json(response.data);
  } catch (err) {
    console.error(`[❌ ERROR] Forwarding failed: ${err.message}`);
    res.status(500).json({ error: 'Proxy error', message: err.message });
  }
});

// === Start server
app.listen(PORT, () => {
  console.log(`✅ API Gateway running on port ${PORT}`);
});
