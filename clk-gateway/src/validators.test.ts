import { isValidSubdomain } from "./validators";

describe("isValidSubdomain", () => {
  test("validates correct subdomains", () => {
    expect(isValidSubdomain("alx")).toBe(true);
    expect(isValidSubdomain("alex-sw")).toBe(true);
    expect(isValidSubdomain("alex19")).toBe(true);
    expect(isValidSubdomain("aliXsed")).toBe(true);
  });

  test("rejects invalid subdomains", () => {
    expect(isValidSubdomain("-invalid")).toBe(false);
    expect(isValidSubdomain("invalid-")).toBe(false);
    expect(isValidSubdomain("inva..lid")).toBe(false);
    expect(isValidSubdomain("inv@lid")).toBe(false);
    expect(isValidSubdomain("")).toBe(false);
  });
});
