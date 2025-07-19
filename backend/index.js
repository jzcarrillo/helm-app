const express = require('express');
const amqp = require('amqplib');
const Redis = require('ioredis');
const { Client } = require('pg');

const app = express();
const PORT = 3000;

// Parse JSON body
app.use(express.json());

// Redis client
const redis = new Redis({ host: 'redis', port: 6379 });

// PostgreSQL client
const pgClient = new Client({
  host: 'postgres-service',
  port: 5432,
  user: 'myuser',
  password: 'mypass',
  database: 'mydb'
});

pgClient.connect()
  .then(() => console.log('[✓] Connected to PostgreSQL'))
  .catch(err => console.error('[✗] PostgreSQL connection error:', err.message));

// Redis: Set a key
app.get('/set', async (req, res) => {
  try {
    await redis.set('mykey', 'Hello from Redis!');
    res.send('✅ Key set in Redis');
  } catch (err) {
    console.error('[✗] Redis SET error:', err.message);
    res.status(500).send('Redis error');
  }
});

// Redis: Get a key
app.get('/get', async (req, res) => {
  try {
    const value = await redis.get('mykey');
    res.send(`Value from Redis: ${value}`);
  } catch (err) {
    console.error('[✗] Redis GET error:', err.message);
    res.status(500).send('Redis error');
  }
});

// PostgreSQL test route
app.get('/dbtest', async (req, res) => {
  try {
    await pgClient.query(`CREATE TABLE IF NOT EXISTS test_table (id SERIAL PRIMARY KEY, message TEXT)`);
    await pgClient.query(`INSERT INTO test_table (message) VALUES ('Hello from PostgreSQL!')`);
    const result = await pgClient.query(`SELECT * FROM test_table`);
    res.json(result.rows);
  } catch (err) {
    console.error('[✗] PostgreSQL error:', err.message);
    res.status(500).send('PostgreSQL error');
  }
});

// Lambda Consumer POST endpoint
app.post('/process', async (req, res) => {
  const payload = req.body;

  if (!payload || Object.keys(payload).length === 0) {
    return res.status(400).json({ message: '❌ Empty or invalid payload' });
  }

  try {
    const message = JSON.stringify(payload);
    await pgClient.query(`CREATE TABLE IF NOT EXISTS test_table (id SERIAL PRIMARY KEY, message TEXT)`);
    await pgClient.query(`INSERT INTO test_table (message) VALUES ($1)`, [message]);
    console.log('[✓] Message inserted into PostgreSQL from Lambda Consumer:', payload);
    res.status(201).json({ message: '✅ Stored in DB' });
  } catch (err) {
    console.error('[✗] Failed to insert into DB:', err.message);
    res.status(500).json({ message: '❌ PostgreSQL insert failed' });
  }
});

// ✅ Health Check Route
app.get('/', async (req, res) => {
  try {
    await pgClient.query('SELECT 1'); // DB connectivity check
    res.send(`
      <html>
        <head><title>Backend</title></head>
        <body style="font-family:sans-serif; padding:20px;">
          <h2 style="color:green;">✅ Backend is running and connected to PostgreSQL</h2>
        </body>
      </html>
    `);
  } catch (err) {
    console.error('❌ DB Connection Error:', err.message);
    res.status(500).send(`
      <html>
        <head><title>Backend</title></head>
        <body style="font-family:sans-serif; padding:20px;">
          <h2 style="color:red;">❌ Backend is running but cannot connect to PostgreSQL</h2>
        </body>
      </html>
    `);
  }
});

// Start Express server
app.listen(PORT, () => {
  console.log(`🚀 Backend listening on port ${PORT}`);
});

// 🔍 Fetch all submitted messages from test_table
app.get('/logs', async (req, res) => {
  try {
    const result = await pgClient.query(`SELECT id, message FROM test_table ORDER BY id DESC`);
    
    // Parse JSON strings into real objects if possible
    const rows = result.rows.map(row => {
      try {
        return { id: row.id, ...JSON.parse(row.message) };
      } catch {
        return { id: row.id, message: row.message };
      }
    });

    res.json(rows);
  } catch (err) {
    console.error('[✗] Failed to fetch from DB:', err.message);
    res.status(500).json({ error: 'Failed to fetch data' });
  }
});
