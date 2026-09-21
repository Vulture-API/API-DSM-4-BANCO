import { randomUUID } from "node:crypto";

import { ReservedUsernameError } from "@/modules/example-users/errors/reserved-username.error.js";
import type { UserRepository } from "@/modules/example-users/repositories/user.repository.js";
import type { CreateUserInput } from "@/modules/example-users/schemas/create-user.schema.js";
import type { User } from "@/modules/example-users/types/user.type.js";

export class CreateUserService {
  constructor(private readonly userRepository: UserRepository) {}

  async create(input: CreateUserInput): Promise<User> {
    const normalizedName = input.name.trim();

    // Lança um erro conhecido para demonstrar o tratamento de erros da aplicação.
    if (normalizedName.toLowerCase() === "admin") {
      throw new ReservedUsernameError();
    }

    const user = {
      id: randomUUID(),
      name: normalizedName,
      email: input.email,
    };

    return this.userRepository.create(user);
  }
}
