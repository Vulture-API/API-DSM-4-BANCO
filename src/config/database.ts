import { Pool } from "pg";

import { env } from "@/config/environment.js";

export const database = new Pool({
  connectionString: env.DATABASE_URL,
});
