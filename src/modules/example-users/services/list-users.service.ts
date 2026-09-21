import type { UserRepository } from "@/modules/example-users/repositories/user.repository.js";
import type { User } from "@/modules/example-users/types/user.type.js";

export class ListUsersService {
  constructor(private readonly userRepository: UserRepository) {}

  async list(): Promise<User[]> {
    return this.userRepository.findAll();
  }
}
