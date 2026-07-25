const express = require('express');
const app = express();
const PORT = process.env.PORT || 3000;

app.get('/', (req, res) => {
  res.json({
    status: 'healthy',
    service: '${{ values.component_id }}',
    owner: '${{ values.owner }}',
    message: 'Welcome to your production-ready Internal Developer Platform service!'
  });
});

app.get('/healthz', (req, res) => res.status(200).send('OK'));

app.listen(PORT, () => {
  console.log(`Server ${{ values.component_id }} is running on port ${PORT}`);
});
