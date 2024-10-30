import { ERC721Token } from "../types";
import { fetchMetadata } from "./utils";
import { missingTokens } from "./missingTokens";

const keysMapping = {
  application: "Application",
  channel: "Channel",
  contentType: "Content Type",
  duration: "Duration (sec)",
  captureDate: "Capture date",
  longitude: "longitude",
  latitude: "Latitude",
  locationPrecision: "Location Precision",
};

function convertArrayToObject(arr: any[]) {
  // validate array
  if (!Array.isArray(arr)) return null;

  return arr.reduce((acc, { trait_type, value }) => {
    acc[trait_type] = value;
    return acc;
  }, {});
}

const fixItems = async (): Promise<any> => {
  logger.info("Fixing missing fields");

  logger.info(`Items without content: ${missingTokens.length}`);

  if (missingTokens.length === 0) return;

  let itemsToSave = [];
  for (const item of missingTokens) {
    const itemContent = await ERC721Token.get(item.id);

    if (itemContent) {
      const token = itemContent;
      if (token.uri) {
        const metadata = await fetchMetadata(token.uri, [
          "nodle-community-nfts.myfilebase.com/ipfs",
          "storage.googleapis.com/ipfs-backups",
        ]);

        if (metadata) {
          token.content = metadata.content || metadata.image || "";
          token.channel = metadata.channel || "";
          token.contentType = metadata.contentType || "";
          token.thumbnail = metadata.thumbnail || "";
          token.name = metadata.name || "";
          token.description = metadata.description || "";
          token.contentHash = metadata.content_hash || "";

          // new metadata from attributes
          if (metadata.attributes && metadata.attributes?.length > 0) {
            const objectAttributes = convertArrayToObject(metadata.attributes);

            if (objectAttributes) {
              token.application = objectAttributes[keysMapping.application];
              token.channel = objectAttributes[keysMapping.channel];
              token.contentType = objectAttributes[keysMapping.contentType];
              token.duration = objectAttributes[keysMapping.duration] || 0;
              token.captureDate = objectAttributes[keysMapping.captureDate]
                ? BigInt(objectAttributes[keysMapping.captureDate])
                : BigInt(0);
              token.longitude = objectAttributes[keysMapping.longitude]
                ? parseFloat(objectAttributes[keysMapping.longitude])
                : 0;
              token.latitude = objectAttributes[keysMapping.latitude]
                ? parseFloat(objectAttributes[keysMapping.latitude])
                : 0;
              token.locationPrecision =
                objectAttributes[keysMapping.locationPrecision];
            }
          }
        }

        itemsToSave.push(token);
      }
    }
  }

  await Promise.all(itemsToSave.map((item) => item.save()));
};

export async function handleFixMissingFields() {
  try {
    logger.error("Starting handleFixMissingFields");
    await fixItems();
  } catch (error) {
    logger.error("ERROR: error in handleFixMissingFields");
    logger.error(error);
    return;
  }
}
