import { env } from "@/config/environment.js";
import { database } from "@/config/database.js";
import { buildApp } from "@/app.js";

const app = buildApp();
let isShuttingDown = false;

async function shutdownApp(signal: NodeJS.Signals) {
  if (isShuttingDown) return;

  isShuttingDown = true;
  console.log(`Received ${signal}. Shutting down application...`);

  try {
    await app.close();

    await database.end();

    console.log("Application shut down.");
  } catch (error) {
    console.error("Error while shutting down application:", error);
    process.exitCode = 1;
  }
}

process.once("SIGINT", () => {
  void shutdownApp("SIGINT");
});

process.once("SIGTERM", () => {
  void shutdownApp("SIGTERM");
});

await app.listen({
  port: env.PORT,
  host: "0.0.0.0",
});

console.log("Server is running!");
console.log(`http://localhost:${env.PORT}`);
