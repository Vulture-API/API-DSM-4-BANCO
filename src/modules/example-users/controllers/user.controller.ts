import type { FastifyReply, FastifyRequest } from "fastify";

import type { CreateUserInput } from "@/modules/example-users/schemas/create-user.schema.js";
import type { CreateUserService } from "@/modules/example-users/services/create-user.service.js";
import type { ListUsersService } from "@/modules/example-users/services/list-users.service.js";

export class UserController {
  constructor(
    private readonly createUserService: CreateUserService,
    private readonly listUsersService: ListUsersService,
  ) {}

  create = async (
    request: FastifyRequest<{ Body: CreateUserInput }>,
    reply: FastifyReply,
  ) => {
    const user = await this.createUserService.create(request.body);

    return reply.status(201).send(user);
  };

  list = async (request: FastifyRequest, reply: FastifyReply) => {
    const users = await this.listUsersService.list();

    return reply.status(200).send(users);
  };
}
