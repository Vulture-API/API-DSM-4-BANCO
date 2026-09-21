import z from "zod";

export const createUserSchema = z.object({
  name: z.string().trim().min(3),
  email: z.email(),
});

export type CreateUserInput = z.infer<typeof createUserSchema>;
