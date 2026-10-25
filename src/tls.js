// TLS setup. Use a real certificate (TLS_CERT_FILE / TLS_KEY_FILE, e.g. from Let's Encrypt),
// or let the server create and keep its own self-signed one for a private network. The app pins
// the key fingerprint printed at startup, so a self-signed certificate is still safe from spoofing.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const os = require('os');
const { execFileSync } = require('child_process');

const dir = path.join(__dirname, '..', 'data', 'tls');

// SHA-256 (hex) of the raw EC public key point. The iPhone app computes the same value from the
// certificate it is shown, so both sides can compare without parsing ASN.1.
function fingerprint(certPem) {
  try {
    const jwk = new crypto.X509Certificate(certPem).publicKey.export({ format: 'jwk' });
    if (jwk.kty !== 'EC') return null;
    const point = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, 'base64url'), Buffer.from(jwk.y, 'base64url')]);
    return crypto.createHash('sha256').update(point).digest('hex');
  } catch { return null; }
}

function selfSigned(baseUrl) {
  const certFile = path.join(dir, 'server.crt');
  const keyFile = path.join(dir, 'server.key');
  if (fs.existsSync(certFile) && fs.existsSync(keyFile)) return { certFile, keyFile };
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  let host = 'localhost';
  try { host = new URL(baseUrl).hostname; } catch { /* keep default */ }
  const names = new Set(['localhost', host, os.hostname()]);
  const sans = ['IP:127.0.0.1'];
  for (const list of Object.values(os.networkInterfaces())) {
    for (const i of list || []) if (i.family === 'IPv4' && !i.internal) sans.push(`IP:${i.address}`);
  }
  for (const n of names) if (n && !/^\d+\.\d+\.\d+\.\d+$/.test(n)) sans.push(`DNS:${n}`);
  execFileSync('openssl', [
    'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes',
    '-days', '3650', '-keyout', keyFile, '-out', certFile, '-subj', '/CN=Clay Shoots',
    '-addext', `subjectAltName=${sans.join(',')}`,
  ], { stdio: 'ignore' });
  fs.chmodSync(keyFile, 0o600);
  return { certFile, keyFile };
}

// Returns { cert, key, fingerprint } when HTTPS is configured, otherwise null.
function load(baseUrl) {
  let certFile = process.env.TLS_CERT_FILE;
  let keyFile = process.env.TLS_KEY_FILE;
  if (!certFile || !keyFile) {
    if (process.env.TLS_SELF_SIGNED !== '1') return null;
    ({ certFile, keyFile } = selfSigned(baseUrl));
  }
  const cert = fs.readFileSync(certFile);
  const key = fs.readFileSync(keyFile);
  return { cert, key, fingerprint: fingerprint(cert.toString()), selfSigned: !process.env.TLS_CERT_FILE };
}

module.exports = { load };
