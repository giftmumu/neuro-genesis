const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const path = require('path');
const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });
app.use(express.static(path.join(__dirname, 'public')));
app.use(express.json());
app.post('/api/set_state', (req, res) => {
  const { state } = req.body;
  console.log(`Visual state: ${state}`);
  wss.clients.forEach(client => {
    if (client.readyState === WebSocket.OPEN)
      client.send(JSON.stringify({ type: 'EMOTION_UPDATE', state }));
  });
  res.json({ status: 'ok' });
});
server.listen(8080, () => console.log('Visual Server running on port 8080'));
