import { describe, expect, it } from "vitest";

import { UserRepository } from "@/modules/example-users/repositories/user.repository.js";
import { ListUsersService } from "@/modules/example-users/services/list-users.service.js";

describe("ListUsersService", () => {
  it("returns an empty list when there are no users", async () => {
    const userRepository = new UserRepository();
    const listUsersService = new ListUsersService(userRepository);

    await expect(listUsersService.list()).resolves.toEqual([]);
  });

  it("lists the users stored in the repository", async () => {
    const userRepository = new UserRepository();
    const listUsersService = new ListUsersService(userRepository);
    const user = {
      id: "user-1",
      name: "Maria",
      email: "maria@example.com",
    };

    await userRepository.create(user);

    await expect(listUsersService.list()).resolves.toEqual([user]);
  });
});
