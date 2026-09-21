import type { FastifyPluginAsyncZod } from "fastify-type-provider-zod";

import { UserController } from "@/modules/example-users/controllers/user.controller.js";
import { UserRepository } from "@/modules/example-users/repositories/user.repository.js";
import { createUserSchema } from "@/modules/example-users/schemas/create-user.schema.js";
import { CreateUserService } from "@/modules/example-users/services/create-user.service.js";
import { ListUsersService } from "@/modules/example-users/services/list-users.service.js";

export const userRoutes: FastifyPluginAsyncZod = async (app) => {
  const userRepository = new UserRepository();
  const createUserService = new CreateUserService(userRepository);
  const listUsersService = new ListUsersService(userRepository);
  const userController = new UserController(
    createUserService,
    listUsersService,
  );

  app.post(
    "/",
    {
      schema: {
        // Um corpo que não corresponde a este esquema gera um erro de validação.
        body: createUserSchema,
      },
    },
    userController.create,
  );

  app.get("/", userController.list);
};
