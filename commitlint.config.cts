import { type UserConfig, RuleConfigSeverity } from "@commitlint/types";

module.exports = {
  extends: ["@commitlint/config-conventional"],
  rules: {
    "subject-case": [RuleConfigSeverity.Error, "always", "sentence-case"],
    "body-max-line-length": [RuleConfigSeverity.Warning, "always", 120],
  },
} satisfies UserConfig;
