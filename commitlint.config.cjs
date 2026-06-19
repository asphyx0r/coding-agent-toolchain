module.exports = {
  defaultIgnores: false,
  parserPreset: {
    parserOpts: {
      headerPattern: /^([^()!:\s]+)(?:\(([^()!\r\n]+)\))?(!)?: (.*)$/,
      headerCorrespondence: ["type", "scope", "breaking", "subject"],
      noteKeywords: ["BREAKING CHANGE", "BREAKING-CHANGE"],
    },
  },
  rules: {
    "body-leading-blank": [2, "always"],
    "footer-leading-blank": [2, "always"],
    "header-trim": [2, "always"],
    "subject-empty": [2, "never"],
    "type-empty": [2, "never"],
  },
};
