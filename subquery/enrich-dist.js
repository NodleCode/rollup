const fs = require('fs');

const filePath = './dist/index.js';
const contentToAdd = `var base64chars =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";

    if (typeof URLSearchParams === "undefined") {
      global.URLSearchParams = require("url").URLSearchParams;
    }
      
    var atob = function (input) {
    var str = String(input).replace(/=+$/, "");
    if (str.length % 4 == 1) {
      throw new Error(
        "'atob' failed: The string to be decoded is not correctly encoded."
      );
    }
    for (
      var bc = 0, bs, buffer, idx = 0, output = "";
      (buffer = str.charAt(idx++));
      ~buffer && ((bs = bc % 4 ? bs * 64 + buffer : buffer), bc++ % 4)
        ? (output += String.fromCharCode(255 & (bs >> ((-2 * bc) & 6))))
        : 0
    ) {
      buffer = base64chars.indexOf(buffer);
    }
    return output;
    };`;
const lineToAdd = 3; // Specify the line number where the content should be added

fs.readFile(filePath, 'utf8', (err, data) => {
    if (err) {
      console.error('Error reading file:', err);
    } else {
      const lines = data.split('\n');
      lines.splice(lineToAdd - 1, 0, ''); // Add a new line
      lines.splice(lineToAdd, 0, contentToAdd); // Insert the content at the specified line number
      const updatedContent = lines.join('\n');

      fs.writeFile(filePath, updatedContent, 'utf8', (err) => {
        if (err) {
            console.error('Error writing file:', err);
        } else {
            console.log('Build completed.');
        }
      });
    }
});
