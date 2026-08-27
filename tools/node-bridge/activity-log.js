'use strict';

const CAP = 200;

function createActivityLog() {
  /** @type {string[]} */
  const lines = [];

  return {
    append(msg) {
      const line = `[openvibble-node] ${msg}`;
      lines.unshift(line);
      if (lines.length > CAP) lines.length = CAP;
      console.log(line);
      return line;
    },
    all() {
      return [...lines];
    },
    clear() {
      lines.length = 0;
    },
  };
}

module.exports = { createActivityLog };
