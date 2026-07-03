import request from "supertest";

// Mock the setup module before importing anything that depends on it
jest.mock("../setup", () => ({
  indexerUrl: "https://indexer.nodleprotocol.io",
  clickNSDomain: "click",
  nodleNSDomain: "nodl",
  parentTLD: "eth",
  clickNameServiceContract: {},
  nodleNameServiceContract: {},
  l1Provider: {},
  l2Wallet: {},
}));

// Mock reserved hashes
jest.mock("../reservedHashes", () => []);

// Mock interfaces
jest.mock("../interfaces", () => ({
  CLICK_RESOLVER_INTERFACE: {},
}));

// Mock helpers
jest.mock("../helpers", () => ({
  asyncHandler: (fn: any) => (req: any, res: any, next: any) => {
    try {
      const result = fn(req, res, next);
      if (result && typeof result.catch === "function") {
        return result.catch(next);
      }
      return result;
    } catch (error) {
      next(error);
    }
  },
  buildTypedData: jest.fn(),
  fetchZyfiSponsored: jest.fn(),
  isOffchainLookupError: jest.fn(),
  isParsableError: jest.fn(),
  validateSignature: jest.fn(),
}));

import express from "express";
import namesRouter from "./names";

// Create test app
const app = express();
app.use(express.json());
app.use("/name", namesRouter);

// Add error handler
app.use((err: any, req: any, res: any, next: any) => {
  if (err.statusCode) {
    res.status(err.statusCode).json({ error: err.message });
  } else {
    res.status(500).json({ error: "Internal server error" });
  }
});

describe("POST /name/validate-handle - Integration Test", () => {
  it("should successfully validate handle ownership against GraphQL indexer and return owned:false when no records found", async () => {
    const testPayload = {
      name: "testuser.click.eth",
      service: "com.twitter",
      handle: "testhandle",
    };

    const response = await request(app)
      .post("/name/validate-handle")
      .send(testPayload)
      .expect("Content-Type", /json/)
      .expect(200);

    // Should return owned: false when no ENS records found
    expect(response.body).toEqual({ owned: false });
  }, 30000);

  it("should return owned:true when text records are found", async () => {
    const testPayload = {
      name: "douglas03.nodl.eth",
      service: "com.x",
      handle: "@douglasacost",
    };

    const response = await request(app)
      .post("/name/validate-handle")
      .send(testPayload)
      .expect(200);

    expect(response.body).toEqual({ owned: true });
  });

  it("should return owned:false when ENS exists but no matching text records", async () => {
    const testPayload = {
      name: "testuser.click.eth",
      service: "com.twitter",
      handle: "testhandle",
    };

    const response = await request(app)
      .post("/name/validate-handle")
      .send(testPayload)
      .expect(200);

    expect(response.body).toEqual({ owned: false });
  });

  it("should return validation errors for invalid input", async () => {
    const invalidPayload = {
      name: "UPPERCASE.click.eth", // Should be lowercase
      service: "invalid-service", // Not in allowed list
      handle: "", // Too short
    };

    const response = await request(app)
      .post("/name/validate-handle")
      .send(invalidPayload)
      .expect(400);

    expect(response.body).toHaveProperty("error");
    expect(response.body.error).toContain("Name must be a lowercase string");
    expect(response.body.error).toContain("Unsupported service");
    expect(response.body.error).toContain(
      "Value must be between 1 and 256 characters",
    );
  });

  it("should reject names that are too short", async () => {
    const shortNamePayload = {
      name: "abc.click.eth", // Only 3 characters, minimum is 5
      service: "com.twitter",
      handle: "testhandle",
    };

    const response = await request(app)
      .post("/name/validate-handle")
      .send(shortNamePayload)
      .expect(400);

    expect(response.body).toHaveProperty("error");
    expect(response.body.error).toContain("at least 5 characters");
  });

  it("should reject unsupported domains", async () => {
    const invalidDomainPayload = {
      name: "testuser.invalid.eth",
      service: "com.twitter",
      handle: "testhandle",
    };

    const response = await request(app)
      .post("/name/validate-handle")
      .send(invalidDomainPayload)
      .expect(400);

    expect(response.body).toHaveProperty("error");
    expect(response.body.error).toContain("Invalid domain or tld");
  });

  it("should reject unsupported services", async () => {
    const unsupportedServicePayload = {
      name: "testuser.click.eth",
      service: "com.facebook", // Not in the allowed list
      handle: "testhandle",
    };

    const response = await request(app)
      .post("/name/validate-handle")
      .send(unsupportedServicePayload)
      .expect(400);

    expect(response.body).toHaveProperty("error");
    expect(response.body.error).toContain("Unsupported service");
  });
});
