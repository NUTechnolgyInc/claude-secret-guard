import { createHash, timingSafeEqual } from "node:crypto";

const digest = (value) => createHash("sha256").update(value).digest();

// True if the request's Bearer token matches the env var named `envName`.
export function hasToken(req, envName) {
  const expected = process.env[envName];
  if (!expected) return false;
  const header = req.headers.authorization || "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  return timingSafeEqual(digest(token), digest(expected));
}
