import type { FastifyInstance } from "fastify";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { buildApp } from "@/app.js";

describe("user routes", () => {
  let app: FastifyInstance;

  beforeEach(() => {
    app = buildApp();
  });

  afterEach(async () => {
    await app.close();
  });

  it("creates a user through the route with the /api prefix", async () => {
    const response = await app.inject({
      method: "POST",
      url: "/api/users",
      payload: {
        name: "Maria",
        email: "maria@example.com",
      },
    });

    expect(response.statusCode).toBe(201);
    expect(response.json()).toEqual({
      id: expect.any(String),
      name: "Maria",
      email: "maria@example.com",
    });
  });

  it("does not expose the route without the /api prefix", async () => {
    const response = await app.inject({
      method: "POST",
      url: "/users",
      payload: {
        name: "Maria",
        email: "maria@example.com",
      },
    });

    expect(response.statusCode).toBe(404);
  });

  it("returns a validation error for an invalid body", async () => {
    const response = await app.inject({
      method: "POST",
      url: "/api/users",
      payload: {
        name: "Ma",
        email: "invalid-email",
      },
    });

    expect(response.statusCode).toBe(400);
    expect(response.json()).toMatchObject({
      statusCode: 400,
      code: "VALIDATION_ERROR",
      message: "Invalid data",
    });
  });

  it("returns the business error for a reserved username", async () => {
    const response = await app.inject({
      method: "POST",
      url: "/api/users",
      payload: {
        name: " ADMIN ",
        email: "admin@example.com",
      },
    });

    expect(response.statusCode).toBe(422);
    expect(response.json()).toEqual({
      statusCode: 422,
      code: "RESERVED_USERNAME",
      message: "The provided username is reserved.",
    });
  });

  it("returns an empty list when there are no users", async () => {
    const response = await app.inject({
      method: "GET",
      url: "/api/users",
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual([]);
  });

  it("lists users created in the same application", async () => {
    const createResponse = await app.inject({
      method: "POST",
      url: "/api/users",
      payload: {
        name: "Maria",
        email: "maria@example.com",
      },
    });

    const listResponse = await app.inject({
      method: "GET",
      url: "/api/users",
    });

    expect(listResponse.statusCode).toBe(200);
    expect(listResponse.json()).toEqual([createResponse.json()]);
  });

  it("does not expose the legacy Portuguese route", async () => {
    const response = await app.inject({
      method: "GET",
      url: "/api/usuarios",
    });

    expect(response.statusCode).toBe(404);
  });

  it("does not accept the legacy Portuguese name field", async () => {
    const response = await app.inject({
      method: "POST",
      url: "/api/users",
      payload: {
        nome: "Maria",
        email: "maria@example.com",
      },
    });

    expect(response.statusCode).toBe(400);
  });
});
