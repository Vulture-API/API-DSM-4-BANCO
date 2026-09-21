import type { User } from "@/modules/example-users/types/user.type.js";

// Defina aqui as funções e consultas que serão executadas no banco de dados.
export class UserRepository {
  private readonly users: User[] = [];

  async create(user: User): Promise<User> {
    this.users.push(user);

    return user;
  }

  // Exemplo:
  // async create(user: User): Promise<User> {
  //   const result = await database.query<User>(
  //     `
  //       INSERT INTO users (id, name, email)
  //       VALUES ($1, $2, $3)
  //       RETURNING id, name, email
  //     `,
  //     [user.id, user.name, user.email],
  //   );

  //   return result.rows[0]!;
  // }

  async findAll(): Promise<User[]> {
    return [...this.users];
  }
}
