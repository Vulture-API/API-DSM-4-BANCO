import { describe, expect, it } from "vitest";

import { ReservedUsernameError } from "@/modules/example-users/errors/reserved-username.error.js";
import { UserRepository } from "@/modules/example-users/repositories/user.repository.js";
import { CreateUserService } from "@/modules/example-users/services/create-user.service.js";

describe("CreateUserService", () => {
  it("creates and persists a user", async () => {
    const userRepository = new UserRepository();
    const createUserService = new CreateUserService(userRepository);

    const user = await createUserService.create({
      name: "  Maria  ",
      email: "maria@example.com",
    });

    expect(user).toEqual({
      id: expect.any(String),
      name: "Maria",
      email: "maria@example.com",
    });
    await expect(userRepository.findAll()).resolves.toEqual([user]);
  });

  it.each(["admin", " ADMIN ", "AdMiN"])(
    "rejects the reserved username %s",
    async (name) => {
      const userRepository = new UserRepository();
      const createUserService = new CreateUserService(userRepository);

      await expect(
        createUserService.create({
          name,
          email: "admin@example.com",
        }),
      ).rejects.toBeInstanceOf(ReservedUsernameError);
    },
  );
});
