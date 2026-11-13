
const { createServer } = require('http');
const { execFile } = require('child_process');
const { timingSafeEqual } = require('crypto');

const PORT = 3000;
const TOKEN = process.env.BRIDGE_TOKEN;

if (!TOKEN) {
  throw new Error('Define BRIDGE_TOKEN antes de iniciar');
}

const server = createServer((req, res) => {
  const reply = (status, data) => {
    if (res.writableEnded) return;

    res.writeHead(status, {
      'Content-Type': 'application/json',
    });

    res.end(JSON.stringify(data));
  };

  if (req.method !== 'POST' || req.url !== '/exec') {
    return reply(404, { error: 'Not found' });
  }

  const received = Buffer.from(
    req.headers.authorization || ''
  );
  const expected = Buffer.from(`Bearer ${TOKEN}`);

  if (
    received.length !== expected.length ||
    !timingSafeEqual(received, expected)
  ) {
    return reply(401, { error: 'Unauthorized' });
  }

  let body = '';

  req.on('data', chunk => {
    body += chunk;

    if (body.length > 4096) {
      req.destroy();
    }
  });

  req.on('end', () => {
    let command;
    let args;

    try {
      ({ command, args = [] } = JSON.parse(body));
    } catch {
      return reply(400, { error: 'Invalid JSON' });
    }

    if (
      typeof command !== 'string' ||
      !command ||
      !Array.isArray(args) ||
      !args.every(arg => typeof arg === 'string')
    ) {
      return reply(400, { error: 'Invalid command or args' });
    }

    execFile(
      command,
      args,
      {
        timeout: 10000,
        maxBuffer: 1024 * 1024,
      },
      (error, stdout, stderr) => {
        reply(200, {
          stdout,
          stderr,
          exitCode: error && typeof error.code === 'number'
            ? error.code
            : error ? 1 : 0,
        });
      }
    );
  });
});

// Apenas localhost por segurança
server.listen(PORT, '127.0.0.1', () => {
  console.log(`Bridge ativa na porta ${PORT}`);
});
