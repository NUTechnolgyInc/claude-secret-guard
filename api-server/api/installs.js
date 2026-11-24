import { hasToken } from "../lib/auth.js";
import { installs } from "../lib/db.js";

// POST /api/installs   (INGEST_TOKEN)  store one installer report
// GET  /api/installs   (ADMIN_TOKEN)   list reports, newest first
//      ?username=&hostname=&status=&event=&limit=  (limit max 500)
// Send header "X-Dry-Run: 1" on POST to check auth and the database without saving.

const STRING_FIELDS = [
  "event", "status", "detail", "script_version", "username",
  "hostname", "os", "os_version", "claude_version", "timestamp",
];
const MAX_LEN = 300;

function clean(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return null;
  const doc = {};
  for (const field of STRING_FIELDS) {
    const value = body[field];
    if (value === undefined || value === null) continue;
    if (typeof value !== "string") return null;
    doc[field] = value.slice(0, MAX_LEN);
  }
  for (const field of ["tests_passed", "tests_failed"]) {
    const value = Number(body[field] ?? 0);
    if (!Number.isInteger(value) || value < 0 || value > 10000) return null;
    doc[field] = value;
  }
  if (!doc.username || !doc.hostname || !["install", "uninstall"].includes(doc.event)) return null;
  return doc;
}

async function create(req, res) {
  if (!hasToken(req, "INGEST_TOKEN")) return res.status(401).json({ error: "unauthorized" });
  const doc = clean(req.body);
  if (!doc) return res.status(400).json({ error: "invalid report" });

  const collection = await installs();
  if (req.headers["x-dry-run"] === "1") {
    await collection.estimatedDocumentCount();
    return res.status(200).json({ ok: true, dry_run: true });
  }
  await collection.insertOne({ ...doc, received_at: new Date() });
  return res.status(201).json({ ok: true });
}

async function list(req, res) {
  if (!hasToken(req, "ADMIN_TOKEN")) return res.status(401).json({ error: "unauthorized" });
  const filter = {};
  for (const field of ["username", "hostname", "status", "event"]) {
    if (typeof req.query[field] === "string" && req.query[field]) filter[field] = req.query[field];
  }
  const limit = Math.min(Math.max(parseInt(req.query.limit, 10) || 100, 1), 500);
  const collection = await installs();
  const rows = await collection
    .find(filter, { projection: { _id: 0 } })
    .sort({ received_at: -1 })
    .limit(limit)
    .toArray();
  return res.status(200).json({ count: rows.length, installs: rows });
}

export default async function handler(req, res) {
  try {
    if (req.method === "POST") return await create(req, res);
    if (req.method === "GET") return await list(req, res);
    res.setHeader("Allow", "GET, POST");
    return res.status(405).json({ error: "method not allowed" });
  } catch (err) {
    console.error("secret-guard-api error:", err.message);
    return res.status(500).json({ error: "server error" });
  }
}
