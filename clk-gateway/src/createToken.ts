/**
 * This script is a tool for test purposes that uses Firebase Admin service account to create a custom token for a user given its UID as the script input.
 *
 * The script performs the following steps:
 * 1. Manually forces the emailVerified status for the specified user to true, avoiding the need to verify the user's email.
 * 2. Uses Firebase Admin SDK to create a custom token for the user.
 * 3. Uses Firebase Client SDK to sign in the user with the custom token and retrieve the ID token.
 * 4. Prints the ID token, which can be used for POST requests on /registerL2 as the bearer token.
 *
 * Environment variables required:
 * - SERVICE_ACCOUNT_KEY: The Firebase Admin service account key in JSON format.
 * - FIREBASE_API_KEY: The Firebase API key.
 * - FIREBASE_PROJECT_ID: The Firebase project ID.
 *
 * Command-line arguments:
 * - userUid: The UID of the user for whom the custom token is to be created. Go to the Firebase Console to find the UID of the user.
 *
 * Usage:
 * ```sh
 * # Note 1: Do not forget to build the project before running the script
 * # Note 2: Do not forget to set the environment variables before running the script
 * # Note 3: There is a possibility that the first time you create a token its email remain unverified. Try to create a second token and use that in that case.
 * yarn createToken <userUid>
 * ```
 *
 * @module createToken
 */

import admin from "firebase-admin";
import { getAuth, signInWithCustomToken } from "firebase/auth";
import { initializeApp } from "firebase/app";

import dotenv from "dotenv";
dotenv.config();

const serviceAccountKey = process.env.SERVICE_ACCOUNT_KEY!;
const serviceAccount = JSON.parse(serviceAccountKey);
admin.initializeApp({
  credential: admin.credential.cert(serviceAccount as admin.ServiceAccount),
});
const firebaseClientConfig = {
  apiKey: process.env.FIREBASE_API_KEY!,
  authDomain: `${process.env.FIREBASE_PROJECT_ID!}.firebaseapp.com`,
};
const app = initializeApp(firebaseClientConfig);
const auth = getAuth(app);

// Get the UID from the command-line arguments
const userUid: string | undefined = process.argv[2];

if (!userUid) {
  console.error("Error: Please provide a user UID as an argument.");
  process.exit(1);
}

async function main(uid: string): Promise<void> {
  try {
    admin
      .auth()
      .updateUser(uid, { emailVerified: true })
      .then((userRecord) => {
        console.log(`Successfully updated user: ${userRecord.email}`);
      })
      .catch((error) => {
        console.error("Error updating user:", error);
      });
    const customToken = await admin.auth().createCustomToken(uid);
    const userCredential = await signInWithCustomToken(auth, customToken);
    const idToken = await userCredential.user.getIdToken();
    console.log("ID Token:", idToken);
  } catch (error) {
    console.error("Error generating token:", error);
  }
}

main(userUid);
