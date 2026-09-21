import "@/config/zod.config.js";

import cookie from "@fastify/cookie";
import Fastify from "fastify";
import {
  serializerCompiler,
  validatorCompiler,
  type ZodTypeProvider,
} from "fastify-type-provider-zod";

import { handleError } from "@/errors/error-handler.js";
import { userRoutes } from "@/modules/example-users/routes/users.route.js";

export function buildApp() {
  const app = Fastify({
    logger: false,
  }).withTypeProvider<ZodTypeProvider>();

  app.setValidatorCompiler(validatorCompiler);
  app.setSerializerCompiler(serializerCompiler);
  app.setErrorHandler(handleError);

  app.register(cookie);
  app.register(userRoutes, { prefix: "/api/users" });

  return app;
}
