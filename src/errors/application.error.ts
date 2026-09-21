// Classe base para erros tratados pelo servidor.
// Erros que estendem esta classe são tratados automaticamente pelo tratador de erros.

export class ApplicationError extends Error {
  public statusCode: number;
  public code: string;

  constructor(statusCode: number, code: string, message: string) {
    super(message);
    this.statusCode = statusCode;
    this.code = code;
    this.name = "ApplicationError";
  }
}
