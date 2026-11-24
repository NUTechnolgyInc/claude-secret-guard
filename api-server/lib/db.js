import { MongoClient } from "mongodb";

const DB_NAME = process.env.MONGODB_DB || "secret_guard";

// Reuse one client across warm function invocations.
let clientPromise;
let indexesReady;

export async function installs() {
  if (!process.env.MONGODB_URI) throw new Error("MONGODB_URI is not set");
  clientPromise ??= new MongoClient(process.env.MONGODB_URI, {
    maxPoolSize: 5,
    serverSelectionTimeoutMS: 5000,
  }).connect();

  const collection = (await clientPromise).db(DB_NAME).collection("installs");
  indexesReady ??= Promise.all([
    collection.createIndex({ received_at: -1 }),
    collection.createIndex({ username: 1, hostname: 1, received_at: -1 }),
  ]);
  await indexesReady;
  return collection;
}
