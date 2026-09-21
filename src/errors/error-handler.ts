import {
  type FastifyError,
  type FastifyReply,
  type FastifyRequest,
} from "fastify";

import { env } from "@/config/environment.js";
import { ApplicationError } from "@/errors/application.error.js";

export function handleError(
  error: FastifyError,
  request: FastifyRequest,
  reply: FastifyReply,
) {
  request.log.error(error);

  const developmentDetails =
    env.NODE_ENV === "development" ? { developmentError: error } : {};

  // Erros encontrados nas validações das rotas feitas pelo Fastify com Zod.
  if (error.validation) {
    return reply.status(400).send({
      statusCode: 400,
      code: "VALIDATION_ERROR",
      message: "Invalid data",
      errors: error.validation,
      ...developmentDetails,
    });
  }

  // Erros conhecidos da aplicação.
  if (error instanceof ApplicationError) {
    return reply.status(error.statusCode).send({
      statusCode: error.statusCode,
      code: error.code,
      message: error.message,
      ...developmentDetails,
    });
  }

  // Erros não tratados.
  return reply.status(500).send({
    statusCode: 500,
    code: "INTERNAL_SERVER_ERROR",
    message: "Internal server error",
    ...developmentDetails,
  });
}
