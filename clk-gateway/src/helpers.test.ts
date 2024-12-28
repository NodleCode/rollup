import { toLengthPrefixedBytes } from "./helpers";

describe("toLengthPrefixedBytes", () => {
  test("example.click.eth", () => {
    const result = toLengthPrefixedBytes("example", "click", "eth");
    expect(result).toEqual(
      Uint8Array.from([
        7, 101, 120, 97, 109, 112, 108, 101, 5, 99, 108, 105, 99, 107, 3, 101,
        116, 104,
      ]),
    );
  });
});
