import { ApplicationError } from "@/errors/application.error.js";

export class ReservedUsernameError extends ApplicationError {
  constructor() {
    super(422, "RESERVED_USERNAME", "The provided username is reserved.");
  }
}
