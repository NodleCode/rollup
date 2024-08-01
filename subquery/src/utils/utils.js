"use strict";
var __awaiter = (this && this.__awaiter) || function (thisArg, _arguments, P, generator) {
    function adopt(value) { return value instanceof P ? value : new P(function (resolve) { resolve(value); }); }
    return new (P || (P = Promise))(function (resolve, reject) {
        function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }
        function rejected(value) { try { step(generator["throw"](value)); } catch (e) { reject(e); } }
        function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }
        step((generator = generator.apply(thisArg, _arguments || [])).next());
    });
};
var __generator = (this && this.__generator) || function (thisArg, body) {
    var _ = { label: 0, sent: function() { if (t[0] & 1) throw t[1]; return t[1]; }, trys: [], ops: [] }, f, y, t, g;
    return g = { next: verb(0), "throw": verb(1), "return": verb(2) }, typeof Symbol === "function" && (g[Symbol.iterator] = function() { return this; }), g;
    function verb(n) { return function (v) { return step([n, v]); }; }
    function step(op) {
        if (f) throw new TypeError("Generator is already executing.");
        while (g && (g = 0, op[0] && (_ = 0)), _) try {
            if (f = 1, y && (t = op[0] & 2 ? y["return"] : op[0] ? y["throw"] || ((t = y["return"]) && t.call(y), 0) : y.next) && !(t = t.call(y, op[1])).done) return t;
            if (y = 0, t) op = [op[0] & 2, t.value];
            switch (op[0]) {
                case 0: case 1: t = op; break;
                case 4: _.label++; return { value: op[1], done: false };
                case 5: _.label++; y = op[1]; op = [0]; continue;
                case 7: op = _.ops.pop(); _.trys.pop(); continue;
                default:
                    if (!(t = _.trys, t = t.length > 0 && t[t.length - 1]) && (op[0] === 6 || op[0] === 2)) { _ = 0; continue; }
                    if (op[0] === 3 && (!t || (op[1] > t[0] && op[1] < t[3]))) { _.label = op[1]; break; }
                    if (op[0] === 6 && _.label < t[1]) { _.label = t[1]; t = op; break; }
                    if (t && _.label < t[2]) { _.label = t[2]; _.ops.push(op); break; }
                    if (t[2]) _.ops.pop();
                    _.trys.pop(); continue;
            }
            op = body.call(thisArg, _);
        } catch (e) { op = [6, e]; y = 0; } finally { f = t = 0; }
        if (op[0] & 5) throw op[1]; return { value: op[0] ? op[1] : void 0, done: true };
    }
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.fetchMetadata = exports.fetchTransaction = exports.getContractDetails = void 0;
exports.fetchAccount = fetchAccount;
var types_1 = require("../types");
var node_fetch_1 = require("node-fetch");
var const_1 = require("./const");
var getContractDetails = function (address) { return __awaiter(void 0, void 0, void 0, function () {
    var symbol, name_1, isErc721, erc1155, isErc20, _a, error_1;
    return __generator(this, function (_b) {
        switch (_b.label) {
            case 0:
                _b.trys.push([0, 8, , 9]);
                return [4 /*yield*/, (0, const_1.callContract)(address, const_1.abi, "symbol")];
            case 1:
                symbol = _b.sent();
                return [4 /*yield*/, (0, const_1.callContract)(address, const_1.abi, "name")];
            case 2:
                name_1 = _b.sent();
                return [4 /*yield*/, (0, const_1.callContract)(address, const_1.abi, "supportsInterface", [
                        "0x80ac58cd",
                    ]).catch(function (error) {
                        logger.info("Error calling supportsInterface for ".concat(address));
                        logger.info(JSON.stringify(error));
                        return false;
                    })];
            case 3:
                isErc721 = _b.sent();
                return [4 /*yield*/, (0, const_1.callContract)(address, const_1.abi, "supportsInterface", [
                        "0xd9b67a26",
                    ]).catch(function (error) {
                        logger.info("Error calling supportsInterface for ".concat(address));
                        logger.info(JSON.stringify(error));
                        return false;
                    })];
            case 4:
                erc1155 = _b.sent();
                logger.info("isErc721: ".concat(isErc721));
                if (!(isErc721 || erc1155)) return [3 /*break*/, 5];
                _a = false;
                return [3 /*break*/, 7];
            case 5: return [4 /*yield*/, (0, const_1.callContract)(address, const_1.abi, "supportsInterface", [
                    "0x36372b07",
                ]).catch(function (error) {
                    logger.info("Error calling supportsInterface for ".concat(address));
                    logger.info(JSON.stringify(error));
                    return true;
                })];
            case 6:
                _a = _b.sent();
                _b.label = 7;
            case 7:
                isErc20 = _a;
                return [2 /*return*/, {
                        symbol: String(symbol),
                        name: String(name_1),
                        isErc721: Boolean(isErc721 || erc1155),
                        isErc20: Boolean(isErc20),
                    }];
            case 8:
                error_1 = _b.sent();
                logger.info("Error getting contract details for ".concat(address));
                logger.info(JSON.stringify(error_1));
                return [2 /*return*/, {
                        symbol: "",
                        name: "",
                        isErc721: false,
                        isErc20: false,
                    }];
            case 9: return [2 /*return*/];
        }
    });
}); };
exports.getContractDetails = getContractDetails;
function fetchAccount(address) {
    return __awaiter(this, void 0, void 0, function () {
        var account;
        return __generator(this, function (_a) {
            switch (_a.label) {
                case 0: return [4 /*yield*/, types_1.Account.get(address)];
                case 1:
                    account = _a.sent();
                    if (!account) {
                        account = new types_1.Account(address);
                        account.save();
                    }
                    return [2 /*return*/, account];
            }
        });
    });
}
var fetchTransaction = function (txHash, timestamp, blocknumber) { return __awaiter(void 0, void 0, void 0, function () {
    var tx, newTx;
    return __generator(this, function (_a) {
        switch (_a.label) {
            case 0: return [4 /*yield*/, types_1.Transaction.get(txHash)];
            case 1:
                tx = _a.sent();
                if (!tx) {
                    logger.info("Transaction not found for hash: ".concat(txHash));
                    newTx = new types_1.Transaction(txHash, timestamp, blocknumber);
                    newTx.save();
                    return [2 /*return*/, newTx];
                }
                return [2 /*return*/, tx];
        }
    });
}); };
exports.fetchTransaction = fetchTransaction;
var fetchMetadata = function (cid, gateways) { return __awaiter(void 0, void 0, void 0, function () {
    var strppedCid, gateway, url, res, err_1, toMatch;
    return __generator(this, function (_a) {
        switch (_a.label) {
            case 0:
                if (gateways.length === 0) {
                    return [2 /*return*/, null];
                }
                logger.info("Fetching metadata for CID: ".concat(cid));
                strppedCid = String(cid).replace("ipfs://", "");
                gateway = gateways[0];
                url = "https://".concat(gateway, "/ipfs/").concat(strppedCid);
                _a.label = 1;
            case 1:
                _a.trys.push([1, 4, , 5]);
                return [4 /*yield*/, (0, node_fetch_1.default)(url)];
            case 2:
                res = _a.sent();
                return [4 /*yield*/, res.json()];
            case 3: return [2 /*return*/, _a.sent()];
            case 4:
                err_1 = _a.sent();
                logger.info(err_1);
                toMatch = ["Unexpected token I in JSON at position 0"];
                if (err_1 instanceof SyntaxError && toMatch.includes(err_1.message)) {
                    return [2 /*return*/, null];
                }
                return [2 /*return*/, (0, exports.fetchMetadata)(cid, gateways.slice(1))];
            case 5: return [2 /*return*/];
        }
    });
}); };
exports.fetchMetadata = fetchMetadata;
