const http = require('http');

const port = process.env.PORT || 8080;
const customerId = process.env.CUSTOMER_ID || 'default';

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(`<!doctype html>
<html lang="zh-Hant">
<head><meta charset="utf-8"><title>Demo Site</title></head>
<body style="font-family: sans-serif; padding: 3rem;">
  <h1>公版 Demo 網站</h1>
  <p>Customer: <strong>${customerId}</strong></p>
  <p>Deployed at: ${new Date().toISOString()}</p>
</body>
</html>`);
});

server.listen(port, () => {
  console.log(`listening on ${port}, customer=${customerId}`);
});
