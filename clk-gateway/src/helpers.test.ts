import { buildTypedData, toLengthPrefixedBytes } from "./helpers";
import { NAME_SERVICE_INTERFACE } from "./interfaces";
import {
  buildZyfiRegisterRequest,
  buildZyfiSetTextRecordRequest,
  nameServiceAddresses,
  zyfiRequestTemplate,
} from "./setup";

const testOwner = "0x1234567890123456789012345678901234567890";
const testSubdomain = "clk";
const testTLD = "eth";
const testName = "example";
describe("toLengthPrefixedBytes", () => {
  test("example.clk.eth", () => {
    const result = toLengthPrefixedBytes(testOwner, testSubdomain, testTLD);
    console.log(result);
    expect(result).toEqual(
      Uint8Array.from([
        42, 48, 120, 49, 50, 51, 52, 53, 54, 55, 56, 57, 48, 49, 50, 51, 52, 53,
        54, 55, 56, 57, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 48, 49, 50, 51,
        52, 53, 54, 55, 56, 57, 48, 3, 99, 108, 107, 3, 101, 116, 104,
      ])
    );
  });
});

describe("buildZyfiRegisterRequest", () => {
  test("example.clk.eth", () => {
    const encodedRegister = NAME_SERVICE_INTERFACE.encodeFunctionData(
      "register",
      [testOwner, testName]
    );
    const result = buildZyfiRegisterRequest(testOwner, testName, testSubdomain);
    expect(result).toEqual({
      ...zyfiRequestTemplate,
      txData: {
        ...zyfiRequestTemplate.txData,
        data: encodedRegister,
        to: nameServiceAddresses[testSubdomain],
      },
    });
  });
});

describe("buildZyfiSetTextRecordRequest", () => {
  test("example.click.eth", () => {
    const encodedSetTextRecord = NAME_SERVICE_INTERFACE.encodeFunctionData(
      "setTextRecord",
      [testName, "test", "test"]
    );
    const result = buildZyfiSetTextRecordRequest(
      testName,
      testSubdomain,
      "test",
      "test"
    );
    expect(result).toEqual({
      ...zyfiRequestTemplate,
      txData: {
        ...zyfiRequestTemplate.txData,
        data: encodedSetTextRecord,
        to: nameServiceAddresses[testSubdomain],
      },
    });
  });
});

describe("buildTypedData", () => {
  test("example.clk.eth", () => {
    const result = buildTypedData(
      {
        test: "test",
      },
      {
        Test: [{ name: "test", type: "string" }],
      }
    );

    expect(result).toEqual({
      domain: { chainId: 300, name: "Nodle Name Service", version: "1" },
      message: { test: "test" },
      primaryType: "Test",
      types: {
        EIP712Domain: [
          { name: "name", type: "string" },
          { name: "version", type: "string" },
          { name: "chainId", type: "uint256" },
        ],
        Test: [{ name: "test", type: "string" }],
      },
    });
  });
});
